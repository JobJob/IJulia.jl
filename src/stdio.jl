# During handling of an execute_request (when execute_msg is !nothing),
# we redirect STDOUT and STDERR into "stream" messages sent to the IPython
# front-end.

const stream_interval = 0.1
const max_bytes = 10*1024
#name=>(iobuffer, parent_msg) for each stream ("stdout","stderr") so they can be sent in flush
typealias BufNStuff Tuple{IOBuffer, Msg, IO}
const cell2stream = Dict{Int, BufNStuff}()

"""Continually read from (size limited) Libuv/OS buffer into an (effectively unlimited) `IObuffer`
to avoid problems when the Libuv/OS buffer gets full (https://github.com/JuliaLang/julia/issues/8789).
Send data immediately when buffer contains more than `max_bytes` bytes. Otherwise, if data is available
it will be sent every `stream_interval` seconds (see the Timers set up in watch_stdio)"""
function watch_stream(rd::IO, name::AbstractString)
    task_local_storage(:IJulia_task, "read $name task")
    # task_local_storage(symbol("stream_",name), rd)
    cell = _n
    parent_msg = execute_msg
    buf = IOBuffer()
    cell2stream[_n] = (buf, parent_msg, rd)
    @vprintln("n is $_n, cell2stream is $cell2stream")
    try
        while !eof(rd) # blocks until something is available
            nb = nb_available(rd)
            if nb > 0
                write(buf, readbytes(rd, nb))
            end
            if buf.size >= max_bytes
                if buf.size >= max_bytes
                    #send immediately
                    send_stream(name, cell, buf, parent_msg)
                end
            end
            # if buf.size > 0
            #     next_send_time[name] = nb > max_bytes ? time() : prev_send_time[name] + stream_interval
            #     @vprintln("next_send_time[name] is $(string(Dates.unix2datetime(next_send_time[name]))[12:end]) buf.size: $buf.size")
            #     if fire_time[send_timer[name]] > next_send_time[name]
            #         Timer(next_send_time[name], schedule_send(name))
            #     tasks[schedsend_task] = "schedsend $name"
            # end
            # @vprintln("$(tasks[current_task()]) will block now and await output in eof()")
        end
    catch e
        # the IPython manager may send us a SIGINT if the user
        # chooses to interrupt the kernel; don't crash on this
        if isa(e, InterruptException)
            watch_stream(rd, name)
        else
            rethrow()
        end
    end
end

function send_stdio(name)
    if verbose::Bool && !haskey(task_local_storage(), :IJulia_task)
        task_local_storage(:IJulia_task, "send $name task")
    end
    send_stream(name)
end

send_stdout(t::Timer) = send_stdio("stdout")
send_stderr(t::Timer) = send_stdio("stderr")

function empty_buffer_filter(cell::Int, buf_and_msg::BufNStuff)
    buf = buf_and_msg[1]
    buf.size > 0
end

function send_stream(name::AbstractString)
    for (cell, buf_and_msg::BufNStuff) in filter(empty_buffer_filter, cell2stream)
        send_stream(name, cell, buf_and_msg[1], buf_and_msg[2])
    end
end

function send_stream(name::AbstractString, cell::Int, buf::IOBuffer, parent_msg::Msg)
    if buf.size > 0
        d = takebuf_array(buf)
        n = num_utf8_trailing(d)
        dextra = d[end-(n-1):end]
        resize!(d, length(d) - n)
        s = UTF8String(d)
        if isvalid(s)
            write(buf, dextra) # assume that the rest of the string will be written later
            length(d) == 0 && return
        else
            # fallback: base64-encode non-UTF8 binary data
            sbuf = IOBuffer()
            print(sbuf, "base64 binary data: ")
            b64 = Base64EncodePipe(sbuf)
            write(b64, d)
            write(b64, dextra)
            close(b64)
            print(sbuf, '\n')
            s = takebuf_string(sbuf)
        end
        send_ipython(publish,
             msg_pub(parent_msg, "stream",
                     @compat Dict("name" => name, "text" => s)))
    end
end

"""
If `d` ends with an incomplete UTF8-encoded character, return the number of trailing incomplete bytes.
Otherwise, return `0`.
"""
function num_utf8_trailing(d::Vector{UInt8})
    i = length(d)
    # find last non-continuation byte in d:
    while i >= 1 && ((d[i] & 0xc0) == 0x80)
        i -= 1
    end
    i < 1 && return 0
    c = d[i]
    # compute number of expected UTF-8 bytes starting at i:
    n = c <= 0x7f ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4
    nend = length(d) + 1 - i # num bytes from i to end
    return nend == n ? 0 : nend
end

# this is hacky: we overload some of the I/O functions on pipe endpoints
# in order to fix some interactions with stdio.
if VERSION < v"0.4.0-dev+6987" # JuliaLang/julia#12739
    const StdioPipe = Base.Pipe
else
    const StdioPipe = Base.PipeEndpoint
end

# IJulia issue #42: there doesn't seem to be a good way to make a task
# that blocks until there is a read request from STDIN ... this makes
# it very hard to properly redirect all reads from STDIN to pyin messages.
# In the meantime, however, we can just hack it so that readline works:
import Base.readline
function readline(io::StdioPipe)
    if io == STDIN
        if !execute_msg.content["allow_stdin"]
            error("IJulia: this front-end does not implement stdin")
        end
        send_ipython(raw_input,
                     msg_reply(execute_msg, "input_request",
                               @compat Dict("prompt"=>"STDIN> ", "password"=>false)))
        while true
            msg = recv_ipython(raw_input)
            if msg.header["msg_type"] == "input_reply"
                return msg.content["value"]
            else
                error("IJulia error: unknown stdin reply")
            end
        end
    else
        invoke(readline, (super(StdioPipe),), io)
    end
end

function watch_stdio()
    task_local_storage(:IJulia_task, "init task")
    redirect_std()
    read_task = @async watch_stream(read_stdout, "stdout")
    if capture_stderr
        readerr_task = @async watch_stream(read_stderr, "stderr")
    end
end

function start_stream_senders()
    #single timer for sending all output
    #send stream msgs every stream_interval secs (if there is output to send)
    Timer(send_stdout, stream_interval, stream_interval)
    if capture_stderr
        Timer(send_stderr, stream_interval, stream_interval)
    end
end

const task2stdout = Dict{Task, IO}()
const task2stderr = Dict{Task, IO}()
function redirect_std()
    global read_stdout
    global write_stdout
    global read_stderr
    global write_stderr

    # @closeall read_stdout write_stdout read_stderr write_stderr
    read_stdout, write_stdout = redirect_stdout()
    t = current_task()
    task2stdout[t] = write_stdout
    if capture_stderr
        read_stderr, write_stderr = redirect_stderr()
        task2stderr[t] = write_stderr
    else
        read_stderr, write_stderr = IOBuffer(), IOBuffer()
    end
end

function get_parent_std(default)
    t = current_task()
    while(true)
        if haskey(task2stdout, t)
            return task2stdout[t]
        end
        t.parent == t && break
        t = t.parent
    end
    return default
end

function Base.print(xs...)
    taskio = get_parent_std(io)
    print(taskio, xs...)
    #invoke(print, (super(StdioPipe),Any), taskio, x)
end

function Base.println(xs...)
    taskio = get_parent_std(STDOUT)
    println(taskio, xs...)
    #invoke(print, (super(StdioPipe),Any), taskio, x)
end

function flush_all()
    flush_cstdio() # flush writes to stdout/stderr by external C code
    flush(STDOUT)
    flush(STDERR)
end

function oslibuv_flush()
    #refs: https://github.com/JuliaLang/IJulia.jl/issues/347#issuecomment-144505862
    #      https://github.com/JuliaLang/IJulia.jl/issues/347#issuecomment-144605024
    @windows_only ccall(:SwitchToThread, stdcall, Void, ())
    yield()
    yield()
end

import Base.flush
function flush(io::StdioPipe)
    invoke(flush, (super(StdioPipe),), io)
    if io == STDOUT
        oslibuv_flush()
        send_stream("stdout")
    elseif io == STDERR
        oslibuv_flush()
        send_stream("stderr")
    end
end


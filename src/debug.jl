# logging in verbose mode goes to original stdio streams.  Use macros
# so that we do not even evaluate the arguments in no-verbose modes

#time() returns utc, now() returns local time
#FYI this could be wrong by -1 second if the now() call happens just before a second boundary and the time() just after
const utcoffset = floor(Dates.datetime2unix(now())) - floor(time())

function get_log_ts(precision=6)
    t = time()
    ms = round(t - floor(t), precision)
    dt = Dates.unix2datetime(floor(t+utcoffset))
    msstr = rpad(string(ms)[3:end], precision, "0")
    ts = "$(string(dt)[12:end]).$msstr"
end

function get_log_preface()
    ts = get_log_ts()
    taskname = get(task_local_storage(), :IJulia_task, "")
    "$ts($taskname): "
end


macro vprintln(x...)
    quote
        if verbose::Bool
            println(orig_STDOUT, get_log_preface(), $(x...))
        end
    end
end

macro verror_show(e, bt)
    quote
        if verbose::Bool
            showerror(orig_STDERR, $e, $bt)
        end
    end
end

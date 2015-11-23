"""
Based on http://underscorejs.org/docs/underscore.html#section-82
Returns a function, that, when invoked, will only be triggered at most once during a given window of time.
Normally, the throttled function will run as much as it can, without ever going more than once per wait duration;
but if you’d like to disable the execution on the leading edge, pass leading=false.
To disable execution on the trailing edge, ditto.
"""
function throttle(func, wait; leading=true, trailing=true )
    timer = Timer((t)->nothing,0.0) #dummy timer that we close immediately
    close(timer)
    previous = 0.0
    return throttled_func(args...) = begin
        later(t) = begin
            previous = leading == false ? 0.0 : time()
            close(timer)
            result = func(args...)
        end
        now = time()
        if previous == 0.0 && leading == false
            previous = now
        end
        remaining = wait - (now - previous)
        if (remaining <= 0.0)
            if (isopen(timer))
                close(timer)
            end
            previous = now
            func(args...)
        elseif (!isopen(timer) && trailing != false)
            timer = Timer(later, remaining)
        else
            println(orig_STDOUT, "throttle: not scheduling and not running")
        end
        return timer
    end
end

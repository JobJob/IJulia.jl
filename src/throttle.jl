"""
Based on http://underscorejs.org/docs/underscore.html#section-82 (Underscore is released under an MIT License)
Returns a function, that, when invoked, will only be triggered at most once during a given window of time.
Normally, the throttled function will run as much as it can, without ever going more than once per wait duration;
but if you’d like to disable the execution on the leading edge, pass leading=false.
To disable execution on the trailing edge, ditto.
"""

throttle(func, wait; leading=true, trailing=true) = begin
    timer = Timer((t)->nothing,0.0) #dummy timer that we close immediately
    close(timer)
    previous = 0.0
    return throttled_func(args...) = begin
        later(t) = begin
            previous = leading == false ? 0.0 : time()
            close(timer)
            # println(orig_STDOUT, get_log_ts(), "here's one we prepared earlier")
            result = func(args...)
        end
        now = time()
        if previous == 0.0 && leading == false
            previous = now
            # println(orig_STDOUT, get_log_ts(), "Your time starts... now")
        end
        remaining = wait - (now - previous)
        if (remaining <= 0.0)
            if (isopen(timer))
                close(timer)
            end
            previous = now
            # println(orig_STDOUT, get_log_ts(), "good timing, remaining: $remaining")
            func(args...)
        elseif (!isopen(timer) && trailing != false)
            timer = Timer(later, remaining)
        end
        return timer
    end
end

"""
Based on http://underscorejs.org/docs/underscore.html#section-82 (Underscore is released under an MIT License)
Returns a function, that, when invoked, will only be triggered at most once during a given window of time.
Normally, the throttled function will run as much as it can, without ever going more than once per wait duration;
but if you’d like to disable the execution on the leading edge, pass leading=false.
To disable execution on the trailing edge, ditto.
"""
throttle(func, wait; leading=true, trailing=true) = begin
    timer = Timer((t)->nothing,0.0)
    #dummy `Timer` that we close immediately to avoid having
    #to check for `timer` being undefined below
    close(timer)
    previous = 0.0
    return throttled_func(args...) = begin
        later(t) = begin
            #later is the function that is scheduled when the task needs to be run later
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
            #the function is ready to be called now
            if (isopen(timer))
                #we're calling func now so close the timer that was ready to call
                #it to avoid calling twice
                close(timer)
            end
            previous = now
            func(args...)
        elseif (!isopen(timer) && trailing != false)
            #if no timer has been set up (and trailing is enabled) then set one up to call the
            #function once the `wait` is over.
            timer = Timer(later, remaining)
        end
        return timer
    end
end

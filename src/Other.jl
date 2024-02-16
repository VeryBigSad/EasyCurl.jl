function stoptimer!(request::Request)
    t = request.timer
    if t !== nothing
        request.timer = nothing
        close(t)
    end
    nothing
end

function timer_callback(
    multi_h    :: Ptr{Cvoid},
    timeout_ms :: Clong,
    request_p    :: Ptr{Cvoid},
)::Cint
    println("timer_callback ", timeout_ms)
    request = unsafe_pointer_to_objref(request_p)::Request
    try
        stoptimer!(request)
        @assert multi_h == request.rq_multi
        if timeout_ms >= 0
            request.timer = Timer(timeout_ms/1000) do timer
                lock(request.lock) do
                    request.timer === timer || return
                    request.timer = nothing
                    curl_multi_socket_action(multi_h, CURL_SOCKET_TIMEOUT, 0, request.response.curl_active)
                    p = curl_multi_info_read(multi_h, Ref{Cint}())
                    p == C_NULL && return
                end
            end
        elseif timeout_ms != -1
            @async @error("timer_callback: invalid timeout value", timeout_ms, maxlog=1_000)
        end
        return 0
    catch err
        @async @error("timer_callback: unexpected error", err=err, maxlog=1_000)
        return -1
    end
end

function socket_callback(
    easy_h    :: Ptr{Cvoid},
    sock      :: curl_socket_t,
    action    :: Cint,
    multi_p   :: Ptr{Cvoid},
    request_p :: Ptr{Cvoid}
)::Cint
    println("socket_callback ", request_p)
    request = unsafe_pointer_to_objref(request_p)::Request
    if watcher_p != C_NULL
        old_watcher = unsafe_pointer_to_objref(watcher_p)::FDWatcher
        curl_multi_assign(multi.handle, sock, C_NULL)
    end
    if action in (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT)
        readable = action in (CURL_POLL_IN,  CURL_POLL_INOUT)
        writable = action in (CURL_POLL_OUT, CURL_POLL_INOUT)
        watcher = FDWatcher(OS_HANDLE(sock), readable, writable)
        preserve_handle(watcher)
        watcher_p = pointer_from_objref(watcher)
        curl_multi_assign(multi.handle, sock, watcher_p)
        task = @async while watcher.readable || watcher.writable # isopen(watcher)
            events = try
                wait(watcher)
            catch err
                err isa EOFError && return
                err isa Base.IOError || rethrow()
                FileWatching.FDEvent()
            end
            flags = CURL_CSELECT_IN  * isreadable(events) +
                    CURL_CSELECT_OUT * iswritable(events) +
                    CURL_CSELECT_ERR * (events.disconnect || events.timedout)
            lock(multi.lock) do
                watcher.readable || watcher.writable || return # !isopen
                curl_multi_socket_action(multi.handle, sock, flags)
                check_multi_info(multi)
            end
        end
        @isdefined(errormonitor) && errormonitor(task)
    end
    return 0
end


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
    # watcher_p :: Ptr{Cvoid},
)::Cint
    println("socket_callback")
    # request = unsafe_pointer_to_objref(multi_p)::Request

    return 0
end


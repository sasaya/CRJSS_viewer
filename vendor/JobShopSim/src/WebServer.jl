mutable struct ServerState
    sim::Simulation
    config::Dict{String,Any}
    running::Bool
    speed::Float64
    last_wall::Float64
    mutex::ReentrantLock
    stopped::Bool
    server::Any
    ticker::Union{Nothing,Task}
end

wall_seconds() = Float64(time_ns()) / 1.0e9

function sync_clock!(state)
    now = wall_seconds()
    if state.running
        advance!(state.sim, state.sim.time + max(0.0, now - state.last_wall) * state.speed; stop_when_complete=true)
        all_jobs_completed(state.sim) && (state.running = false)
    end
    state.last_wall = now
end

function state_snapshot(state)
    data = snapshot(state.sim)
    data["running"] = state.running
    data["speed"] = state.speed
    data["completed"] = !isempty(state.sim.reserved_ids) && all_jobs_completed(state.sim)
    data
end

json_response(status, data) = HTTP.Response(status,
    ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"], JSON3.write(data))

function parse_body(req)
    try
        data = JSON3.read(String(req.body), Dict{String,Any})
        data isa AbstractDict || throw(ArgumentError("JSONオブジェクトが必要です"))
        return data
    catch
        throw(ArgumentError("有効なJSONオブジェクトを送信してください"))
    end
end

function handle_request(state, req)
    path = first(split(req.target, '?'))
    try
        if req.method == "GET" && path == "/"
            return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"],
                read(joinpath(pkgdir(@__MODULE__), "web", "index.html"), String))
        elseif req.method == "GET" && path == "/api/state"
            return lock(state.mutex) do
                sync_clock!(state)
                json_response(200, state_snapshot(state))
            end
        elseif req.method == "GET" && path == "/api/config"
            return lock(state.mutex) do
                json_response(200, state.config)
            end
        elseif req.method == "POST" && path == "/api/input"
            data = parse_body(req)
            return lock(state.mutex) do
                sync_clock!(state)
                accepted = submit!(state.sim, data)
                json_response(200, Dict("accepted" => accepted, "state" => state_snapshot(state)))
            end
        elseif req.method == "POST" && path == "/api/config"
            data = normalize_config(parse_body(req))
            sim = load_config(data) # Build and validate entirely before replacing the live state.
            return lock(state.mutex) do
                state.sim = sim
                state.config = deepcopy(data)
                state.running = false
                state.last_wall = wall_seconds()
                json_response(200, state_snapshot(state))
            end
        elseif req.method == "POST" && path == "/api/scenarios/sequence/preview"
            input = parse_body(req)
            entries = required(input, "entries")
            entries isa AbstractVector && !isempty(entries) || throw(ArgumentError("シナリオを1件以上選択してください"))
            configs = Any[]
            for entry in entries
                entry isa AbstractDict || throw(ArgumentError("各シナリオはJSONオブジェクトで指定してください"))
                data = if haskey(entry, "path")
                    file = required(entry, "path")
                    file isa AbstractString || throw(ArgumentError("path は文字列で指定してください"))
                    read_config_file(file; import_options=get(input, "import_options", nothing))
                else
                    raw = deepcopy(required(entry, "config"))
                    raw isa AbstractDict || throw(ArgumentError("config はJSONオブジェクトで指定してください"))
                    haskey(raw, "W") && (raw["import_options"] = get(input, "import_options", Dict()))
                    normalized = normalize_config(raw)
                    info = get!(normalized, "input_info", Dict{String,Any}())
                    haskey(entry, "name") && (info["source_file"] = identifier(entry["name"], "scenario name"))
                    normalized
                end
                get(get(data, "input_info", Dict()), "format", "") == "W/R/N/V/L/U" ||
                    throw(ArgumentError("ジョブシナリオにはW/R/N/V/L/U形式を指定してください"))
                push!(configs, data)
            end
            config = build_sequence_config(configs; mode=get(input,"mode","completion_or_time"),
                interval=get(input,"interval",60), count=get(input,"transport_count",1))
            return json_response(200, Dict("config" => config, "preview" => snapshot(load_config(config))))
        elseif req.method == "POST" && path == "/api/scenarios/preview"
            input = parse_body(req)
            file_path = required(input, "path")
            file_path isa AbstractString || throw(ArgumentError("path はJSONファイルのパスで指定してください"))
            data = read_config_file(strip(file_path); import_options=get(input, "import_options", nothing))
            get(get(data, "input_info", Dict()), "format", "") == "W/R/N/V/L/U" ||
                throw(ArgumentError("ジョブシナリオにはinput_data.jsonと同じW/R/N/V/L/U形式を指定してください"))
            # Job scenario selection never implicitly enables a fault scenario.
            data["faults"] = Dict("mode" => "none")
            filter!(event -> get(event, "type", "") == "add_job", data["events"])
            sim = load_config(data)
            return json_response(200, Dict("config" => data, "preview" => snapshot(sim)))
        elseif req.method == "POST" && path == "/api/config/file"
            input = parse_body(req)
            path = required(input, "path")
            path isa AbstractString || throw(ArgumentError("path はファイルパスの文字列で指定してください"))
            data = read_config_file(path; import_options=get(input, "import_options", nothing))
            sim = load_config(data)
            return lock(state.mutex) do
                state.sim = sim
                state.config = data
                state.running = false
                state.last_wall = wall_seconds()
                json_response(200, state_snapshot(state))
            end
        elseif req.method == "POST" && path == "/api/transporters"
            data = parse_body(req)
            count = transport_count(required(data, "count"))
            return lock(state.mutex) do
                sync_clock!(state)
                configure_transporters!(state.sim, count)
                state.config["transport_count"] = count
                state.last_wall = wall_seconds()
                json_response(200, state_snapshot(state))
            end
        elseif req.method == "POST" && path == "/api/faults"
            data = parse_body(req)
            return lock(state.mutex) do
                sync_clock!(state)
                configure_faults!(state.sim, data)
                # Reset reapplies the selected mode, but current absolute scenario times remain explicit.
                state.config["faults"] = deepcopy(state.sim.faults)
                if haskey(state.config, "events")
                    filter!(e -> get(e, "type", "") == "add_job", state.config["events"])
                end
                state.last_wall = wall_seconds()
                json_response(200, state_snapshot(state))
            end
        elseif req.method == "POST" && path == "/api/control"
            data = parse_body(req)
            action = required(data, "action")
            action in ("start", "pause", "step", "speed", "reset") || throw(ArgumentError("未知の操作: $action"))
            seconds = action == "step" ? number(required(data, "seconds"), "seconds"; positive=true) : 0.0
            speed = action == "speed" ? number(required(data, "speed"), "speed"; positive=true) : 1.0
            return lock(state.mutex) do
                action == "step" && state.running && throw(ArgumentError("ステップ実行は一時停止中に使用してください"))
                sync_clock!(state)
                if action == "start"
                    state.running = !all_jobs_completed(state.sim)
                elseif action == "pause"
                    state.running = false
                elseif action == "step"
                    advance!(state.sim, state.sim.time + seconds; stop_when_complete=true)
                elseif action == "speed"
                    state.speed = speed
                elseif action == "reset"
                    state.sim = load_config(state.config)
                    state.running = false
                end
                state.last_wall = wall_seconds()
                json_response(200, state_snapshot(state))
            end
        end
        json_response(404, Dict("error" => "エンドポイントが見つかりません"))
    catch err
        if err isa ArgumentError
            return json_response(400, Dict("error" => err.msg))
        end
        @error "HTTP request failed" exception=(err, catch_backtrace())
        json_response(500, Dict("error" => "内部エラーが発生しました。サーバーログを確認してください"))
    end
end

"""Start a local HTTP dashboard and a 50 Hz monotonic-clock simulation driver."""
function start_server(config; host="127.0.0.1", port=8080, speed=1.0, autostart=false)
    data = config isa AbstractString ? read_config_file(config) : normalize_config(config)
    sim = load_config(data)
    rate = number(speed, "speed"; positive=true)
    state = ServerState(sim, data, autostart && !all_jobs_completed(sim), rate, wall_seconds(), ReentrantLock(), false, nothing, nothing)
    state.server = HTTP.serve!(req -> handle_request(state, req), host, port; verbose=false, listenany=(port == 0))
    state.last_wall = wall_seconds()
    state.ticker = @async begin
        try
            while true
                sleep(0.02)
                stop = lock(state.mutex) do
                    state.stopped && return true
                    sync_clock!(state)
                    false
                end
                stop && break
            end
        catch err
            lock(state.mutex) do
                state.running = false
            end
            @error "Simulation clock stopped" exception=(err, catch_backtrace())
        end
    end
    state
end

function stop_server!(state::ServerState)
    lock(state.mutex) do
        state.stopped = true
        state.running = false
    end
    close(state.server)
    state.ticker !== nothing && wait(state.ticker)
    nothing
end

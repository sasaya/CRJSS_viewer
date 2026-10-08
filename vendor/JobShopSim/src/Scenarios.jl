# Scenario launches run inside settle!, so completion and deadline triggers are exact events.
function prepare_scenarios!(sim, entries)
    entries isa AbstractVector || throw(ArgumentError("scenario_sequence は配列で指定してください"))
    for (i, entry) in enumerate(entries)
        entry isa AbstractDict || throw(ArgumentError("各シナリオはJSONオブジェクトで指定してください"))
        mode = get(entry, "mode", "completion_or_time")
        mode in ("completion", "time", "completion_or_time") || throw(ArgumentError("開始条件が不正です"))
        interval = number(get(entry, "interval", 60), "interval"; positive=true)
        jobs = required(entry, "jobs")
        jobs isa AbstractVector && !isempty(jobs) || throw(ArgumentError("各シナリオにジョブを1件以上指定してください"))
        prepared = Any[]
        for data in jobs
            job = parse_job(sim, data)
            release = number(get(data, "release", 0), "release")
            push!(sim.reserved_ids, job.id)
            push!(prepared, (job, release))
        end
        push!(sim.scenario_sequence, Dict{String,Any}("id" => "S$i", "name" => identifier(get(entry, "name", "シナリオ$i"), "scenario name"),
            "machine_groups" => deepcopy(get(entry,"machine_groups",Dict())), "mode" => mode, "interval" => interval, "prepared" => prepared,
            "job_ids" => [pair[1].id for pair in prepared], "started" => nothing, "completed" => nothing))
    end
end

function update_scenarios!(sim)
    launched = false
    for (i, scenario) in enumerate(sim.scenario_sequence)
        if scenario["started"] !== nothing && scenario["completed"] === nothing &&
            all(haskey(sim.jobs, id) && sim.jobs[id].status == "completed" for id in scenario["job_ids"])
            scenario["completed"] = sim.time
            record!(sim, "scenario_completed"; scenario=scenario["id"])
        end
        scenario["started"] !== nothing && continue
        ready = i == 1
        if i > 1
            prev = sim.scenario_sequence[i-1]
            if prev["started"] !== nothing
                done = prev["completed"] !== nothing
                elapsed = sim.time >= prev["started"] + prev["interval"]
                ready = prev["mode"] == "completion" ? done : prev["mode"] == "time" ? elapsed : done || elapsed
            end
        end
        ready || continue
        scenario["started"] = sim.time
        for (prototype, release) in scenario["prepared"]
            job = deepcopy(prototype)
            at = sim.time + release
            isfinite(at) || throw(ArgumentError("シナリオの投入時刻が計算範囲を超えています"))
            job.entered = at
            enqueue!(sim, "add_job", at, job, "scenario_sequence")
        end
        record!(sim, "scenario_started"; scenario=scenario["id"], name=scenario["name"])
        launched = true
    end
    launched
end

function scenario_snapshot(sim)
    [Dict("id" => e["id"], "name" => e["name"], "machine_groups" => deepcopy(e["machine_groups"]), "mode" => e["mode"], "interval" => e["interval"],
        "job_ids" => copy(e["job_ids"]), "started" => e["started"], "completed" => e["completed"],
        "status" => e["completed"] !== nothing ? "completed" : e["started"] !== nothing ? "running" : "pending",
        "completed_jobs" => count(id -> haskey(sim.jobs,id) && sim.jobs[id].status == "completed", e["job_ids"]),
        "next_deadline" => i < length(sim.scenario_sequence) && e["started"] !== nothing && e["mode"] != "completion" ? e["started"]+e["interval"] : nothing)
     for (i,e) in enumerate(sim.scenario_sequence)]
end

function build_sequence_config(configs; mode="completion_or_time", interval=60, count=1)
    configs isa AbstractVector && !isempty(configs) || throw(ArgumentError("シナリオを1件以上選択してください"))
    mode in ("completion", "time", "completion_or_time") || throw(ArgumentError("開始条件が不正です"))
    delay = number(interval, "interval"; positive=true)
    transporters = transport_count(count)
    machines = String[]
    entries = Any[]
    groups = Dict{String,Any}()
    memberships = Dict{String,Tuple{Int,Vector{String}}}()
    warnings = String[]
    for (i, raw) in enumerate(configs)
        config = Dict{String,Any}(normalize_config(raw))
        config["faults"] = Dict("mode" => "none")
        config["scenario_sequence"] = Any[]
        filter!(e -> get(e,"type","") == "add_job", get(config,"events",Any[]))
        model = load_config(config)
        for id in model.machine_order
            id in machines || push!(machines,id)
            members = model.machine_groups[model.machine_group[id]]
            if haskey(memberships,id)
                previous, old_members = memberships[id]
                if Set(old_members) != Set(members)
                    push!(warnings,"複数シナリオの機械グループ定義が一致しません: $id（S$previous: $(join(old_members,"/"))、S$i: $(join(members,"/"))）。各シナリオの候補機械を保持し、同じ実機を共有して実行します。")
                end
            else
                memberships[id] = (i,copy(members))
            end
        end
        # The first scenario supplies defaults for additional external jobs; planned jobs carry their own candidates.
        i == 1 && (groups = deepcopy(model.machine_groups))
        definitions = vcat(get(config,"jobs",Any[]),
            [merge(Dict{String,Any}(e["job"]), Dict("release" => get(e,"at",0))) for e in get(config,"events",Any[])])
        jobs = Any[]
        for definition in definitions
            operations = [Dict{String,Any}(op) for op in definition["operations"]]
            for op in operations
                source_machine = identifier(op["machine"], "machine")
                if !haskey(op,"machine_group_members")
                    op["machine"] = model.machine_group[source_machine]
                    op["machine_group_members"] = copy(model.machine_groups[op["machine"]])
                end
            end
            for k in 2:length(operations)
                if !haskey(operations[k],"travel_before") && !haskey(operations[k],"travel_times")
                    # A transfer can only connect the preceding operation's
                    # candidates to this operation's candidates. Repeating the
                    # complete plant matrix for every JOB multiplies large lots.
                    operations[k]["travel_times"] = Dict(from => Dict(to => from == to ? 0.0 :
                        get(get(model.travel_times,from,Dict()),to,model.default_travel_time)
                        for to in operations[k]["machine_group_members"])
                        for from in operations[k-1]["machine_group_members"])
                end
            end
            push!(jobs, Dict("id" => "S$i:" * identifier(definition["id"], "job id"), "operations" => operations, "release" => get(definition,"release",0)))
        end
        source = get(get(config,"input_info",Dict()),"source_file","シナリオ$i")
        name = last(split(replace(source, '\\' => '/'), '/'))
        push!(entries, Dict("name" => name, "machine_groups" => deepcopy(model.machine_groups), "mode" => mode, "interval" => delay, "jobs" => jobs))
    end
    config = Dict{String,Any}("machines" => machines, "machine_groups" => groups, "transport_count" => transporters,
        "input_info" => Dict("warnings" => unique(warnings)), "jobs" => Any[], "events" => Any[], "faults" => Dict("mode" => "none"), "scenario_sequence" => entries)
    load_config(config) # Validate the entire sequence before exposing or applying it.
    config
end

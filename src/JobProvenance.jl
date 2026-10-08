const MODES = ("fifo","fixed_priority","compute_only","optimized_priority")
const SOLVER_CALLBACK_SUPPORT=Dict("cp_sat"=>true,"highs"=>true)
supports_solution_callback(solver)=get(SOLVER_CALLBACK_SUPPORT,solver,false) &&
    (solver!="cp_sat" || isfile(joinpath(ROOT,"vendor","HoistScheduling","vendor","history_bridge","build",Sys.iswindows() ? "hoist_observer.exe" : "hoist_observer")))
function normalize_optimizer(input)
    input isa AbstractDict || throw(ArgumentError("optimizer はJSONオブジェクトです"))
    opts = merge(Dict{String,Any}("period_sim_seconds"=>60.0,"solver_limit_wall_seconds"=>60.0,
        "request_limit_wall_seconds"=>300.0,"solver"=>"cp_sat","workers"=>min(8,max(1,Sys.CPU_THREADS-1)),"seed"=>1,"upper"=>10000,
        "on_job_added"=>true,"on_failure"=>true,"on_repair"=>true,"warmup"=>false,"delay_job_release"=>true,
        "recalculation_mode"=>"events","stop_condition"=>"time","gap_percent"=>1.0,"pattern_delivery"=>"final",
        "simulation_start_mode"=>"parallel","transfer_execution"=>"priority"),deepcopy(input))
    opts["transfer_execution"] in ("priority","cyclic_timing") || throw(ArgumentError("搬送実行方式は priority または cyclic_timing です"))
    if opts["transfer_execution"]=="cyclic_timing"
        opts["simulation_start_mode"]=="after_optimization" || throw(ArgumentError("完全一致の搬送には「計算完了後にJOB投入」を選択してください"))
        opts["delay_job_release"]==true || throw(ArgumentError("完全一致の搬送には周期に合わせたJOB投入調整が必要です"))
    end
    opts["simulation_start_mode"] in ("parallel","after_optimization") || throw(ArgumentError("シミュレーション開始モードは parallel または after_optimization です"))
    opts["pattern_delivery"] in ("final","incremental") || throw(ArgumentError("パターン受け渡しは final または incremental です"))
    opts["pattern_delivery"]=="incremental" && !supports_solution_callback(opts["solver"]) && throw(ArgumentError("このソルバーでは対応していません"))
    opts["stop_condition"] in OPTIMIZATION_STOP_CONDITIONS || throw(ArgumentError("終了条件は gap、time、time_or_gap のいずれかです"))
    gap=JS.number(opts["gap_percent"],"gap_percent")
    0<=gap<=100 || throw(ArgumentError("gap_percent は0〜100です"))
    opts["recalculation_mode"] in ("events","periodic") || throw(ArgumentError("再計算モードは events または periodic です"))
    opts["solver"] in ("cp_sat","highs") || throw(ArgumentError("solver は cp_sat または highs を指定してください"))
    for key in ("period_sim_seconds","solver_limit_wall_seconds","request_limit_wall_seconds")
        JS.number(opts[key],key;positive=true)
    end
    for key in ("workers","seed","upper")
        opts[key] isa Integer && !(opts[key] isa Bool) && opts[key] >= (key=="seed" ? 0 : 1) || throw(ArgumentError("$key が不正です"))
    end
    opts["upper"] <= 10000 || throw(ArgumentError("Big-M=10000のモデルのためupperは10000以下です"))
    for key in ("on_job_added","on_failure","on_repair","warmup","delay_job_release")
        opts[key] isa Bool || throw(ArgumentError("$key は真偽値です"))
    end
    opts
end
function normalize_control(input)
    input isa AbstractDict || throw(ArgumentError("control はJSONオブジェクトです"))
    control=merge(Dict{String,Any}("mode"=>"optimized_priority","blocked_candidate"=>"skip",
        "transporter_assignment"=>"first_idle","unranked_candidate"=>"fifo_after_ranked"),deepcopy(input))
    mode = control["mode"]
    mode in MODES || throw(ArgumentError("制御モードが不正です"))
    for (key,value) in (("blocked_candidate","skip"),("transporter_assignment","first_idle"),("unranked_candidate","fifo_after_ranked"))
        control[key]==value || throw(ArgumentError("初版の$key は$value です"))
    end
    control
end
function compact_sequence_travel!(config)
    for scenario in get(config,"scenario_sequence",Any[]),job in get(scenario,"jobs",Any[])
        operations=get(job,"operations",Any[])
        for k in 2:length(operations)
            previous,current=operations[k-1],operations[k]
            haskey(previous,"machine_group_members") && haskey(current,"machine_group_members") && haskey(current,"travel_times") || continue
            matrix=current["travel_times"]
            compact=Dict{String,Any}()
            for from in previous["machine_group_members"]
                haskey(matrix,from) || continue
                row=matrix[from]
                compact[from]=Dict(to=>row[to] for to in current["machine_group_members"] if haskey(row,to))
            end
            current["travel_times"]=compact
        end
    end
    config
end
function prepare_config(input)
    # Copy the path we edit first, compact its matrices, and only then deep-copy
    # the entire configuration. Old 60-lot files otherwise peak at two complete
    # mutable plant matrices per operation before we discard their unused cells.
    config=Dict{String,Any}(input)
    if haskey(config,"scenario_sequence")
        config["scenario_sequence"]=[merge(Dict{String,Any}(scenario),Dict("jobs"=>[
            merge(Dict{String,Any}(job),Dict("operations"=>[Dict{String,Any}(op) for op in job["operations"]]))
            for job in scenario["jobs"]])) for scenario in config["scenario_sequence"]]
    end
    compact_sequence_travel!(config)
    config=deepcopy(config)
    opts=normalize_optimizer(get(config,"optimizer",Dict()))
    control=normalize_control(get(config,"control",Dict()))
    opts["transfer_execution"]=="cyclic_timing" && !(control["mode"] in ("optimized_priority","fixed_priority")) && throw(ArgumentError("完全一致の搬送はオンライン優先順位または固定優先順位で使用してください"))
    config["control"] = control
    config["optimizer"] = opts
    original = get(config,"source_problem",nothing)
    source_file = nothing
    if haskey(config,"problem_path")
        path = config["problem_path"]
        source_file = input_path(path)
        original = read_input_json(source_file)
    elseif haskey(config,"W")
        original = Dict(k=>deepcopy(config[k]) for k in ("W","R","N","V","L","U","Capacity","E","D") if haskey(config,k))
    end
    mapping = Dict{String,Any}()
    opts["transfer_execution"]=="cyclic_timing" && original===nothing && throw(ArgumentError("完全一致方式には最適化原入力W/R/N/V/L/Uが必要です"))
    if original !== nothing
        original = Dict{String,Any}(original)
        get!(original,"Capacity",Dict{String,Any}())
        # The integer CP-SAT model must never silently truncate fractional input.
        function integral(x)
            x isa AbstractDict && return all(integral,values(x))
            x isa AbstractVector && return all(integral,x)
            x isa Real && return !(x isa Bool) && isfinite(x) && isinteger(x) && 0 <= x <= 10000
            false
        end
        integral(original) || throw(ArgumentError("最適化原入力は0〜10000の整数で指定してください"))
        raw = deepcopy(original); raw["import_options"] = get(config,"import_options",Dict())
        raw["faults"] = get(config,"faults",Dict("mode"=>"none"))
        raw["events"] = get(config,"events",Any[])
        normalized = JS.normalize_config(raw)
        source_file!==nothing && (normalized["input_info"]["source_file"]=source_file)
        pid = problem_hash(original)
        copies = normalized["input_info"]["copies_per_route"]
        for (idx, job) in enumerate(normalized["jobs"])
            r = cld(idx,copies)
            m = Dict("problem_id"=>pid,"scenario_id"=>"S1","route_id"=>r,
                "instance_index"=>mod(idx-1,copies)+1,"job_id"=>job["id"],"operation_count"=>original["N"][r])
            job["provenance"] = m; mapping[job["id"]] = m
        end
        if haskey(config,"machines")
            # Normalized previews carry explicit provenance. Never infer it from display names.
            normalized = deepcopy(config)
            empty!(mapping)
            definitions = vcat(get(normalized,"jobs",Any[]),[e["job"] for e in get(normalized,"events",Any[]) if e["type"]=="add_job"],
                [j for s in get(normalized,"scenario_sequence",Any[]) for j in s["jobs"]])
            for j in definitions
                if haskey(j,"provenance")
                    m=deepcopy(j["provenance"])
                    m["problem_id"]==pid && m["job_id"]==j["id"] || throw(ArgumentError("入力由来情報が不一致です"))
                    mapping[j["id"]]=m
                end
            end
        end
        config = merge(normalized, Dict("source_problem"=>original,"optimizer"=>opts,"control"=>config["control"],
            "import_options"=>get(config,"import_options",Dict()),"clock"=>get(config,"clock",Dict("speed"=>1))))
    else
        config = merge(JS.normalize_config(config),Dict("optimizer"=>opts,"control"=>config["control"]))
    end
    # Validate mappings against the actual simulator operations, including travel and group definitions.
    prototype = original === nothing ? nothing : JS.load_config(merge(deepcopy(original),Dict("import_options"=>get(config,"import_options",Dict()))))
    for (id,m) in mapping
        r=m["route_id"]
        1 <= r <= original["R"] || throw(ArgumentError("route_idが不正です"))
        m["instance_index"] isa Integer && m["instance_index"]>=1 || throw(ArgumentError("instance_indexが不正です"))
        m["operation_count"] == original["N"][r] || throw(ArgumentError("工程数が不一致です"))
    end
    if !isempty(mapping)
        blank=merge(deepcopy(config),Dict("jobs"=>Any[],"events"=>Any[],"scenario_sequence"=>Any[],"faults"=>Dict("mode"=>"none")))
        machine_model=JS.load_config(blank)
        definitions=vcat(get(config,"jobs",Any[]),[e["job"] for e in get(config,"events",Any[]) if e["type"]=="add_job"],
            [j for s in get(config,"scenario_sequence",Any[]) for j in s["jobs"]])
        raw=deepcopy(original);raw["import_options"]=merge(get(config,"import_options",Dict()),Dict("copies_per_route"=>1))
        expected=JS.load_config(JS.normalize_config(raw))
        for definition in definitions
            haskey(mapping,definition["id"]) || continue
            actual=JS.parse_job(machine_model,definition)
            reference=expected.jobs[expected.job_order[mapping[definition["id"]]["route_id"]]]
            length(actual.operations)==length(reference.operations) || throw(ArgumentError("経路の工程数不一致"))
            for i in eachindex(actual.operations)
                a,b=actual.operations[i],reference.operations[i]
                a.machine==b.machine && a.duration==b.duration && a.members==b.members || throw(ArgumentError("原経路と工程が一致しません"))
                i==1 && continue
                for from in reference.operations[i-1].members, to in b.members
                    JS.travel_duration(machine_model,from,a;to)==JS.travel_duration(expected,from,b;to) || throw(ArgumentError("原経路と移動時間が一致しません"))
                end
            end
        end
        instances=[(m["route_id"],m["instance_index"]) for m in values(mapping)]
        length(instances)==length(unique(instances)) || throw(ArgumentError("品種コピー番号重複"))
    end
    config, original, mapping
end

function registered_mapping(app)
    [deepcopy(m) for (id,m) in app.mapping if id in app.sim.reserved_ids]
end

# Merge different route scenarios on the same equipment into a stable catalog.
# Identical route definitions keep the same ID across repeated scenarios.
function sequence_problem_catalog(configs)
    problems=[get(c,"source_problem",nothing) for c in configs]
    all(p->p!==nothing,problems) || throw(ArgumentError("連続最適化には各シナリオの原W/R/N/V/L/U入力が必要です"))
    if all(p->p==first(problems),problems)
        return deepcopy(first(problems)),[collect(1:p["R"]) for p in problems]
    end
    first_problem=first(problems)
    all(p->p["W"]==first_problem["W"] && p["E"]==first_problem["E"] &&
        get(p,"Capacity",Dict())==get(first_problem,"Capacity",Dict()),problems) ||
        throw(ArgumentError("異なる経路を連続投入する場合、W・E・Capacityの設備定義を共通にしてください"))
    routes=Any[];lookup=Dict{String,Int}();route_maps=Vector{Vector{Int}}()
    for p in problems
        map=Int[]
        for r in 1:p["R"]
            N=Int(p["N"][r]);V=[p["V"][i][r] for i in 1:N+1]
            D=[V[i]==V[i+1] ? 0 : haskey(p,"D") ? p["D"][i][r] : 20+p["E"][V[i]][V[i+1]] for i in 1:N]
            route=Dict("N"=>N,"V"=>V,"L"=>[p["L"][i][r] for i in 1:N],
                "U"=>[p["U"][i][r] for i in 1:N],"D"=>D)
            key=canonical(route)
            if !haskey(lookup,key);push!(routes,route);lookup[key]=length(routes);end
            push!(map,lookup[key])
        end
        push!(route_maps,map)
    end
    maxN=maximum(r["N"] for r in routes)
    problem=Dict{String,Any}("W"=>deepcopy(first_problem["W"]),"E"=>deepcopy(first_problem["E"]),
        "Capacity"=>deepcopy(get(first_problem,"Capacity",Dict())),"R"=>length(routes),"N"=>[r["N"] for r in routes])
    for key in ("V","L","U","D")
        problem[key]=[[i<=length(r[key]) ? r[key][i] : 0 for r in routes] for i in 1:maxN+Int(key=="V")]
    end
    problem,route_maps
end

function route_job(app, data)
    app.problem === nothing && throw(ArgumentError("原経路がありません"))
    r = data["route_id"]
    r isa Integer && !(r isa Bool) && 1<=r<=app.problem["R"] || throw(ArgumentError("route_idが不正です"))
    raw=deepcopy(app.problem)
    raw["import_options"]=merge(get(app.config,"import_options",Dict()),Dict("copies_per_route"=>1))
    prototype=JS.normalize_config(raw)["jobs"][r]
    id=JS.identifier(data["id"],"job id")
    prototype["id"]=id
    n=maximum((m["instance_index"] for m in values(app.mapping) if m["route_id"]==r);init=0)+1
    prototype["provenance"]=Dict("problem_id"=>app.problem_id,"scenario_id"=>get(data,"scenario_id","external"),
        "route_id"=>r,"instance_index"=>n,"job_id"=>id,"operation_count"=>app.problem["N"][r])
    prototype
end

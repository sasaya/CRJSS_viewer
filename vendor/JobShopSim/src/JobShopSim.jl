module JobShopSim

using JSON3
using HTTP
using Random

export Simulation, advance!, submit!, snapshot, load_config, configure_faults!, configure_transporters!, start_server, stop_server!

struct Operation
    machine::String
    duration::Float64
    travel_before::Union{Nothing,Float64}
    travel_times::Union{Nothing,Dict{String,Dict{String,Float64}}}
    members::Vector{String}
end
Operation(machine::String, duration::Float64) = Operation(machine, duration, nothing, nothing, [machine])
Operation(machine::String, duration::Float64, before::Union{Nothing,Float64}) = Operation(machine, duration, before, nothing, [machine])

mutable struct Job
    id::String
    operations::Vector{Operation}
    index::Int
    remaining::Float64
    status::String
    entered::Float64
    completed::Union{Nothing,Float64}
    processed::Float64
    travel_start::Union{Nothing,Float64}
    travel_until::Union{Nothing,Float64}
    travel_from::Union{Nothing,String}
    moved::Float64
    transporter::Union{Nothing,Int}
    transport_wait_start::Union{Nothing,Float64}
    transport_waited::Float64
    assigned_machine::Union{Nothing,String}
end

mutable struct Transporter
    id::String
    active::Union{Nothing,String}
    busy::Float64
end

mutable struct Machine
    id::String
    failed::Bool
    active::Union{Nothing,String}
    queue::Vector{String}
    busy::Float64
    downtime::Float64
    segment_start::Union{Nothing,Float64}
end

struct InputEvent
    at::Float64
    sequence::Int
    kind::String
    payload::Any
    source::String
end

mutable struct Simulation
    time::Float64
    machines::Dict{String,Machine}
    machine_order::Vector{String}
    jobs::Dict{String,Job}
    job_order::Vector{String}
    reserved_ids::Set{String}
    events::Vector{InputEvent}
    sequence::Int
    history::Vector{Dict{String,Any}}
    log::Vector{Dict{String,Any}}
    faults::Dict{String,Any}
    rng::MersenneTwister
    travel_times::Dict{String,Dict{String,Float64}}
    default_travel_time::Float64
    transfers::Vector{Dict{String,Any}}
    input_info::Dict{String,Any}
    transporters::Vector{Transporter}
    transfer_queue::Vector{String}
    scenario_sequence::Vector{Dict{String,Any}}
    machine_groups::Dict{String,Vector{String}}
    machine_group::Dict{String,String}
    machine_reservations::Dict{String,String}
    transfer_selector::Any
    event_observer::Any
    before_transfer_dispatch::Any
    holding_history::Vector{Dict{String,Any}}
    advance_enabled::Bool
    next_transfer_time::Any
    defer_zero_transfers::Bool
    machine_dispatch_guard::Any
    after_settle::Any
end

function identifier(value, label)
    value isa AbstractString || throw(ArgumentError("$label は文字列で指定してください"))
    s = strip(String(value))
    isempty(s) && throw(ArgumentError("$label は空にできません"))
    length(s) <= 80 || throw(ArgumentError("$label は80文字以内で指定してください"))
    s
end

function number(value, label; positive=false)
    value isa Real && !(value isa Bool) || throw(ArgumentError("$label は数値で指定してください"))
    x = Float64(value)
    isfinite(x) && (positive ? x > 0 : x >= 0) ||
        throw(ArgumentError("$label は有限の$(positive ? "正の" : "非負の")数値で指定してください"))
    x
end

function required(data, key)
    data isa AbstractDict || throw(ArgumentError("JSONオブジェクトを指定してください"))
    haskey(data, key) || throw(ArgumentError("$key が必要です"))
    data[key]
end

function Simulation(ids::AbstractVector)
    isempty(ids) && throw(ArgumentError("機械を1台以上指定してください"))
    names = [identifier(id, "machine id") for id in ids]
    length(unique(names)) == length(names) || throw(ArgumentError("機械IDが重複しています"))
    machines = Dict(id => Machine(id, false, nothing, String[], 0.0, 0.0, nothing) for id in names)
    Simulation(0.0, machines, names, Dict{String,Job}(), String[], Set{String}(),
               InputEvent[], 0, Dict{String,Any}[], Dict{String,Any}[],
               Dict{String,Any}("mode" => "none", "events" => Any[]), MersenneTwister(1),
               Dict{String,Dict{String,Float64}}(), 0.0, Dict{String,Any}[], Dict{String,Any}(),
               [Transporter("T1", nothing, 0.0)], String[], Dict{String,Any}[], Dict(id => [id] for id in names), Dict(id => id for id in names), Dict{String,String}(), nothing, nothing, nothing, Dict{String,Any}[], true, nothing, false, nothing, nothing)
end

function record!(sim, kind; fields...)
    entry = Dict{String,Any}("time" => sim.time, "type" => kind)
    for (key, value) in pairs(fields)
        entry[String(key)] = value
    end
    push!(sim.log, entry)
    sim.event_observer !== nothing && sim.event_observer(sim, entry)
end

function configure_machine_groups!(sim, groups)
    groups isa AbstractDict || throw(ArgumentError("machine_groups はオブジェクトで指定してください"))
    claimed = Set{String}()
    for (raw_group, raw_members) in groups
        group = identifier(raw_group, "group")
        raw_members isa AbstractVector && !isempty(raw_members) || throw(ArgumentError("機械グループのメンバーを指定してください"))
        members = [identifier(id,"group member") for id in raw_members]
        group in members || throw(ArgumentError("グループの代表機械をメンバーに含めてください"))
        all(haskey(sim.machines,id) for id in members) || throw(ArgumentError("グループに未知の機械があります"))
        length(unique(members)) == length(members) && isempty(intersect(claimed,Set(members))) || throw(ArgumentError("機械グループが重複しています"))
        union!(claimed,members)
        for id in members
            delete!(sim.machine_groups,id)
            sim.machine_group[id] = group
        end
        sim.machine_groups[group] = members
    end
    sim
end

function parse_job(sim, data)
    id = identifier(required(data, "id"), "job id")
    id in sim.reserved_ids && throw(ArgumentError("ジョブID $id は登録済みです"))
    raw = required(data, "operations")
    raw isa AbstractVector && !isempty(raw) || throw(ArgumentError("operations に工程を1つ以上指定してください"))
    ops = Operation[]
    for op in raw
        machine = identifier(required(op, "machine"), "machine")
        haskey(sim.machines, machine) || throw(ArgumentError("未知の機械: $machine"))
        travel = haskey(op, "travel_before") ? number(op["travel_before"], "travel_before") : nothing
        isempty(ops) && travel !== nothing && travel > 0 && throw(ArgumentError("最初の工程にはtravel_beforeを指定できません"))
        members = if haskey(op,"machine_group_members")
            raw_members = op["machine_group_members"]
            raw_members isa AbstractVector && !isempty(raw_members) || throw(ArgumentError("machine_group_members に候補機械を指定してください"))
            names = [identifier(id,"member") for id in raw_members]
            all(haskey(sim.machines,id) for id in names) && machine in names && length(unique(names)) == length(names) ||
                throw(ArgumentError("工程の候補機械が不正です"))
            names
        else
            machine = sim.machine_group[machine]
            copy(sim.machine_groups[machine])
        end
        matrix = nothing
        if haskey(op,"travel_times")
            raw_matrix = op["travel_times"]
            raw_matrix isa AbstractDict || throw(ArgumentError("工程のtravel_timesはオブジェクトで指定してください"))
            matrix = Dict{String,Dict{String,Float64}}()
            for (from, destinations) in raw_matrix
                haskey(sim.machines,from) && destinations isa AbstractDict || throw(ArgumentError("工程の移動元が不正です"))
                matrix[from] = Dict{String,Float64}()
                for (to, value) in destinations
                    haskey(sim.machines,to) || throw(ArgumentError("工程の移動先が不正です"))
                    matrix[from][to] = number(value,"travel_times[$from][$to]")
                end
            end
        end
        push!(ops, Operation(machine, number(required(op, "duration"), "duration"), travel, matrix, members))
    end
    Job(id, ops, 1, ops[1].duration, "queued", sim.time, nothing, 0.0, nothing, nothing, nothing, 0.0, nothing, nothing, 0.0, nothing)
end

function travel_duration(sim, from, operation; to=operation.machine)
    operation.travel_before !== nothing && return operation.travel_before
    from == to && return 0.0
    times = operation.travel_times === nothing ? sim.travel_times : operation.travel_times
    get(get(times, from, Dict{String,Float64}()), to, sim.default_travel_time)
end

function start_transfer!(sim, job, from)
    duration = travel_duration(sim, from, job.operations[job.index])
    if duration == 0 && !sim.defer_zero_transfers
        sim.event_observer !== nothing && record!(sim,"transfer_consumed";job=job.id,source_operation=job.index-1,reason="zero_duration")
        queue_job!(sim, job)
        return
    end
    job.status = "waiting_transport"
    job.travel_from = from
    job.transport_wait_start = sim.time
    push!(sim.transfer_queue, job.id)
    record!(sim, "transport_requested"; job=job.id, from=from, to=job.operations[job.index].machine)
end

function available_group_machine(sim, job)
    group = job.operations[job.index].machine
    candidates = filter(id -> !sim.machines[id].failed && (sim.machines[id].active === nothing ||
        sim.machines[id].active==job.id && job.status=="waiting_transport") &&
        isempty(sim.machines[id].queue) && !haskey(sim.machine_reservations,id), job.operations[job.index].members)
    isempty(candidates) ? nothing : first(candidates)
end

function dispatch_transfers!(sim)
    instant = false
    for (index, transporter) in enumerate(sim.transporters)
        transporter.active !== nothing && continue
        position = if sim.transfer_selector === nothing
            findfirst(id -> length(sim.jobs[id].operations[sim.jobs[id].index].members) == 1 ||
                available_group_machine(sim, sim.jobs[id]) !== nothing, sim.transfer_queue)
        else
            applicable(sim.transfer_selector,sim,index) ? sim.transfer_selector(sim,index) : sim.transfer_selector(sim)
        end
        position === nothing && continue
        job = sim.jobs[sim.transfer_queue[position]]
        group = job.operations[job.index].machine
        target = length(job.operations[job.index].members) == 1 ? group : available_group_machine(sim, job)
        duration = travel_duration(sim, job.travel_from, job.operations[job.index]; to=target)
        until = sim.time + duration
        isfinite(until) && (duration == 0 || until > sim.time) || throw(ArgumentError("移動時間が時刻の計算可能な範囲を超えています"))
        deleteat!(sim.transfer_queue, position)
        source=sim.machines[job.travel_from]
        if source.active==job.id
            if sim.time>job.transport_wait_start
                push!(sim.holding_history,Dict{String,Any}("machine"=>source.id,"job"=>job.id,"operation"=>job.index-1,
                    "start"=>job.transport_wait_start,"end"=>sim.time,"kind"=>"holding"))
            end
            source.active=nothing
            record!(sim,"machine_released";job=job.id,machine=source.id,reason="transfer_started")
            instant=true # Dispatch the next upstream job at this same simulation time.
        end
        job.transport_waited += sim.time - job.transport_wait_start
        job.transport_wait_start = nothing
        job.assigned_machine = target
        if duration == 0
            sim.event_observer !== nothing && record!(sim,"transfer_consumed";job=job.id,source_operation=job.index-1,reason="zero_duration")
            job.travel_from = nothing
            queue_job!(sim, job)
            instant = true
            continue
        end
        job.status = "moving"
        job.travel_start = sim.time
        job.travel_until = until
        job.transporter = index
        transporter.active = job.id
        length(job.operations[job.index].members) > 1 && (sim.machine_reservations[target] = job.id)
        record!(sim, "transfer_started"; job=job.id, from=job.travel_from,
            to=target, duration=duration, transporter=transporter.id)
    end
    instant
end

function transport_count(value)
    value isa Integer && !(value isa Bool) && 1 <= value <= 10000 ||
        throw(ArgumentError("transport_count は1〜10000の整数で指定してください"))
    Int(value)
end

function configure_transporters!(sim::Simulation, value)
    count = transport_count(value)
    old_count = length(sim.transporters)
    if count < old_count
        any(t.active !== nothing for t in sim.transporters[count+1:end]) &&
            throw(ArgumentError("削減する搬送機械が搬送中です。搬送終了後に台数を減らしてください"))
        resize!(sim.transporters, count)
    elseif count > old_count
        append!(sim.transporters, [Transporter("T$i", nothing, 0.0) for i in old_count+1:count])
    end
    count != old_count && record!(sim, "transport_count_changed"; count=count)
    advance!(sim, sim.time)
    sim
end

function complete_transfers!(sim)
    for id in sim.job_order
        job = sim.jobs[id]
        if job.status == "moving" && job.travel_until <= sim.time
            push!(sim.transfers, Dict{String,Any}("job" => id, "from" => job.travel_from,
                "to" => job.assigned_machine, "start" => job.travel_start, "end" => job.travel_until,
                "transporter" => sim.transporters[job.transporter].id))
            job.moved += job.travel_until - job.travel_start
            record!(sim, "transfer_completed"; job=id, from=job.travel_from, to=job.assigned_machine,
                transporter=sim.transporters[job.transporter].id)
            delete!(sim.machine_reservations, job.assigned_machine)
            sim.transporters[job.transporter].active = nothing
            job.transporter = nothing
            job.travel_start = job.travel_until = nothing
            job.travel_from = nothing
            queue_job!(sim, job)
        end
    end
end

function queue_job!(sim, job)
    job.status = "queued"
    push!(sim.machines[something(job.assigned_machine, job.operations[job.index].machine)].queue, job.id)
end

function close_segment!(sim, m)
    if m.segment_start !== nothing
        job = sim.jobs[m.active]
        push!(sim.history, Dict{String,Any}("machine" => m.id, "job" => job.id,
            "operation" => job.index, "start" => m.segment_start, "end" => sim.time))
        m.segment_start = nothing
    end
end

function apply_event!(sim, event)
    if event.kind == "add_job"
        job = event.payload::Job
        job.entered = sim.time
        sim.jobs[job.id] = job
        push!(sim.job_order, job.id)
        queue_job!(sim, job)
        record!(sim, "job_added"; job=job.id,source=event.source)
    elseif event.kind == "release_job"
        job=sim.jobs[event.payload]
        if job.status=="waiting_release"
            job.entered=sim.time
            queue_job!(sim,job)
            record!(sim,"job_released";job=job.id)
        end
    else
        m = sim.machines[event.payload]
        if event.kind == "fail_machine"
            if !m.failed
                close_segment!(sim, m)
                m.failed = true
                m.active !== nothing && sim.jobs[m.active].status=="running" && (sim.jobs[m.active].status = "blocked")
                record!(sim, "machine_failed"; machine=m.id, source=event.source)
            end
        elseif m.failed
            m.failed = false
            if m.active !== nothing && sim.jobs[m.active].status=="blocked"
                sim.jobs[m.active].status = "running"
                m.segment_start = sim.time
            end
            record!(sim, "machine_repaired"; machine=m.id, source=event.source)
        end
        if event.source == "random" && event.kind == "repair_machine" && sim.faults["mode"] == "random"
            schedule_random!(sim, m.id)
        end
    end
end

"""Validate and submit an immediate or future external input. No wall-clock dependency."""
function validate_input(sim::Simulation, data)
    kind = required(data, "type")
    kind in ("add_job", "fail_machine", "repair_machine") || throw(ArgumentError("未知の入力種別: $kind"))
    at = number(get(data, "at", sim.time), "at")
    at >= sim.time || throw(ArgumentError("過去の時刻には入力できません（現在 $(sim.time) 秒）"))
    payload = if kind == "add_job"
        parse_job(sim, required(data, "job"))
    else
        id = identifier(required(data, "machine"), "machine")
        haskey(sim.machines, id) || throw(ArgumentError("未知の機械: $id"))
        id
    end
    (String(kind), at, payload)
end

function enqueue!(sim, kind, at, payload, source)
    kind == "add_job" && push!(sim.reserved_ids, payload.id)
    sim.sequence += 1
    event = InputEvent(at, sim.sequence, kind, payload, source)
    push!(sim.events, event)
    sort!(sim.events; by=e -> (e.at, e.sequence))
    Dict("sequence" => event.sequence, "at" => at, "type" => kind)
end

function submit!(sim::Simulation, data; settle=true)
    kind, at, payload = validate_input(sim, data)
    kind == "fail_machine" && sim.faults["mode"] == "none" &&
        throw(ArgumentError("故障なしモードでは故障入力を受け付けません。故障モードを明示的に変更してください"))
    accepted = enqueue!(sim, kind, at, payload, "external")
    settle && advance!(sim, sim.time)
    accepted
end

function validate_faults(sim, data)
    mode = get(data, "mode", "none")
    mode in ("none", "random", "scenario") || throw(ArgumentError("故障モードは none / random / scenario から選んでください"))
    policy = Dict{String,Any}("mode" => mode, "events" => Any[])
    if mode == "scenario"
        events = get(data, "events", Any[])
        events isa AbstractVector || throw(ArgumentError("故障シナリオの events は配列で指定してください"))
        for input in events
            kind = required(input, "type")
            kind in ("fail_machine", "repair_machine") || throw(ArgumentError("故障シナリオには故障・復旧のみ指定できます"))
            kind, at, machine = validate_input(sim, input)
            push!(policy["events"], Dict("type" => kind, "at" => at, "machine" => machine))
        end
    elseif mode == "random"
        settings = get(data, "random", Dict{String,Any}())
        settings isa AbstractDict || throw(ArgumentError("random はJSONオブジェクトで指定してください"))
        seed = get(settings, "seed", 1)
        seed isa Integer && !(seed isa Bool) && 0 <= seed <= typemax(Int) || throw(ArgumentError("seed は非負の整数で指定してください"))
        uptime = number(get(settings, "mean_uptime", 30), "mean_uptime"; positive=true)
        repair = number(get(settings, "repair_duration", 6), "repair_duration"; positive=true)
        min(uptime, repair) >= 0.001 || throw(ArgumentError("ランダム故障の時間は0.001秒以上にしてください"))
        ids = get(settings, "machines", sim.machine_order)
        ids isa AbstractVector && !isempty(ids) || throw(ArgumentError("ランダム故障の対象機械を1台以上指定してください"))
        names = [identifier(id, "machine") for id in ids]
        all(haskey(sim.machines, id) for id in names) || throw(ArgumentError("ランダム故障に未知の機械が含まれています"))
        length(unique(names)) == length(names) || throw(ArgumentError("ランダム故障の対象機械が重複しています"))
        policy["random"] = Dict("seed" => Int(seed), "mean_uptime" => uptime, "repair_duration" => repair, "machines" => names)
    end
    policy
end

function schedule_random!(sim, machine)
    settings = sim.faults["random"]
    delay = max(0.001, randexp(sim.rng) * settings["mean_uptime"])
    at = sim.time + delay
    repaired_at = at + settings["repair_duration"]
    isfinite(repaired_at) && sim.time < at < repaired_at || throw(ArgumentError("ランダム故障時刻が計算可能な範囲を超えています"))
    enqueue!(sim, "fail_machine", at, machine, "random")
    enqueue!(sim, "repair_machine", repaired_at, machine, "random")
end

"""Explicitly select a fault policy, cancel old fault inputs, and recover failed machines."""
function configure_faults!(sim::Simulation, data; settle=true)
    data isa AbstractDict || throw(ArgumentError("faults はJSONオブジェクトで指定してください"))
    policy = validate_faults(sim, data)
    # Build the replacement on a copy so validation/scheduling failures are atomic.
    # Policy callbacks can close over their owning server. Preserve these references
    # instead of recursively cloning the server and its process/lock state.
    replacement = Simulation(sim.machine_order)
    for field in fieldnames(Simulation)
        value = getfield(sim, field)
        setfield!(replacement, field, field in (:transfer_selector, :event_observer, :before_transfer_dispatch, :next_transfer_time, :machine_dispatch_guard, :after_settle) ? value : deepcopy(value))
    end
    filter!(e -> e.kind in ("add_job","release_job"), replacement.events)
    for id in replacement.machine_order
        apply_event!(replacement, InputEvent(replacement.time, 0, "repair_machine", id, "mode_change"))
    end
    replacement.faults = policy
    if policy["mode"] == "scenario"
        for input in policy["events"]
            enqueue!(replacement, input["type"], input["at"], input["machine"], "scenario")
        end
    elseif policy["mode"] == "random"
        replacement.rng = MersenneTwister(policy["random"]["seed"])
        for id in policy["random"]["machines"]
            schedule_random!(replacement, id)
        end
    end
    record!(replacement, "fault_mode_changed"; mode=policy["mode"])
    settle && advance!(replacement, replacement.time)
    for field in fieldnames(Simulation)
        setfield!(sim, field, getfield(replacement, field))
    end
    sim
end

function complete_operations!(sim)
    for id in sim.machine_order
        m = sim.machines[id]
        m.active === nothing && continue
        job = sim.jobs[m.active]
        job.status in ("running","blocked") || continue
        # Completion is allowed even if a fault is scheduled at this exact time.
        job.remaining > 0 && continue
        close_segment!(sim, m)
        record!(sim, "operation_completed"; job=job.id, machine=id, operation=job.index)
        job.index += 1
        if job.index > length(job.operations)
            m.active = nothing
            job.status = "completed"
            job.completed = sim.time
            record!(sim, "job_completed"; job=job.id)
        else
            job.remaining = job.operations[job.index].duration
            job.assigned_machine = nothing
            # A finished job remains on its source machine while waiting for a hoist.
            travel_duration(sim,id,job.operations[job.index])==0 && !sim.defer_zero_transfers && (m.active=nothing)
            start_transfer!(sim, job, id)
        end
    end
end

function dispatch!(sim)
    for id in sim.machine_order
        m = sim.machines[id]
        (m.failed || m.active !== nothing) && continue
        reserved=haskey(sim.machine_reservations,id)
        reserved && sim.machine_dispatch_guard===nothing && continue
        allowed(jid)=!reserved || sim.machine_dispatch_guard(sim,sim.jobs[jid],id)
        own = findfirst(jid -> sim.jobs[jid].assigned_machine == id && allowed(jid), m.queue)
        queue = m.queue
        position = own
        if position === nothing
            for source in sim.machine_order
                queue = sim.machines[source].queue
                position = findfirst(jid -> sim.jobs[jid].assigned_machine === nothing &&
                    id in sim.jobs[jid].operations[sim.jobs[jid].index].members && allowed(jid), queue)
                position !== nothing && break
            end
        end
        position === nothing && continue
        job = sim.jobs[splice!(queue,position)]
        job.assigned_machine = id
        m.active = job.id
        job.status = "running"
        m.segment_start = sim.time
        record!(sim, "operation_started"; job=job.id, machine=id, group=job.operations[job.index].machine, operation=job.index)
    end
end

function settle!(sim)
    sim.advance_enabled || return
    while true
        complete_operations!(sim)
        complete_transfers!(sim)
        while !isempty(sim.events) && first(sim.events).at <= sim.time
            apply_event!(sim, popfirst!(sim.events))
        end
        dispatch!(sim)
        # Zero-duration loading/unloading stages settle immediately, with finite route lengths.
        while any(m.active !== nothing && !m.failed && sim.jobs[m.active].status=="running" && sim.jobs[m.active].remaining == 0 for m in values(sim.machines))
            complete_operations!(sim)
            dispatch!(sim)
        end
        sim.before_transfer_dispatch !== nothing && sim.before_transfer_dispatch(sim)
        instant = dispatch_transfers!(sim)
        launched = update_scenarios!(sim)
        if !(instant || launched)
            sim.after_settle!==nothing && sim.after_settle(sim)
            break
        end
    end
end

"""All configured, scheduled and not-yet-launched scenario jobs have completed."""
all_jobs_completed(sim::Simulation) = length(sim.jobs) == length(sim.reserved_ids) &&
    all(j.status == "completed" for j in values(sim.jobs))

"""Advance exactly across every arrival, fault, repair and operation completion."""
function advance!(sim::Simulation, target::Real; stop_when_complete=false)
    goal = number(target, "target")
    goal >= sim.time || throw(ArgumentError("時刻を逆戻りさせることはできません"))
    sim.advance_enabled || return sim
    settle!(sim)
    while sim.time < goal
        stop_when_complete && all_jobs_completed(sim) && break
        boundary = goal
        if sim.next_transfer_time!==nothing
            next=sim.next_transfer_time(sim)
            # A stopped timing policy returns the current time. Do not spin,
            # skip an appointment or accumulate busy seconds after a mismatch.
            next!==nothing && next<=sim.time && break
            next!==nothing && (boundary=min(boundary,next))
        end
        for i in 2:length(sim.scenario_sequence)
            previous, current = sim.scenario_sequence[i-1], sim.scenario_sequence[i]
            if current["started"] === nothing && previous["started"] !== nothing && previous["mode"] != "completion"
                boundary = min(boundary, previous["started"] + previous["interval"])
            end
        end
        !isempty(sim.events) && (boundary = min(boundary, first(sim.events).at))
        for job in values(sim.jobs)
            job.status == "moving" && (boundary = min(boundary, job.travel_until))
        end
        for m in values(sim.machines)
            if !m.failed && m.active !== nothing && sim.jobs[m.active].status=="running"
                finish = sim.time + sim.jobs[m.active].remaining
                finish > sim.time || throw(ArgumentError("処理時間が現在時刻の浮動小数点精度より小さすぎます"))
                boundary = min(boundary, finish)
            end
        end
        dt = boundary - sim.time
        for transporter in sim.transporters
            transporter.active !== nothing && (transporter.busy += dt)
        end
        for m in values(sim.machines)
            if m.failed
                m.downtime += dt
            elseif m.active !== nothing && sim.jobs[m.active].status=="running"
                job = sim.jobs[m.active]
                # Compare against the same finish expression used to select boundary.
                finishes = sim.time + job.remaining <= boundary
                used = finishes ? job.remaining : dt
                job.remaining = finishes ? 0.0 : max(0.0, job.remaining - dt)
                job.processed += used
                m.busy += used
            end
        end
        sim.time = boundary
        settle!(sim)
    end
    sim
end

function snapshot(sim::Simulation;history_since=-Inf)
    machines = Any[]
    for id in sim.machine_order
        m = sim.machines[id]
        job = m.active === nothing ? nothing : sim.jobs[m.active]
        holding=job!==nothing && job.status=="waiting_transport"
        operation=job===nothing ? nothing : job.index-Int(holding)
        held_seconds=sum(h["end"]-h["start"] for h in sim.holding_history if h["machine"]==id;init=0.0)+
            (holding ? sim.time-job.transport_wait_start : 0.0)
        push!(machines, Dict("id" => id, "group" => sim.machine_group[id], "reserved_job" => get(sim.machine_reservations,id,nothing), "status" => m.failed ? "failed" : job === nothing ? "idle" : holding ? "holding" : "running",
            "job" => m.active, "operation" => operation,
            "duration" => job === nothing ? 0.0 : job.operations[operation].duration,
            "processed" => job === nothing ? 0.0 : holding ? job.operations[operation].duration : job.operations[operation].duration - job.remaining,
            "remaining" => job === nothing || holding ? 0.0 : job.remaining,
            "holding_seconds"=>held_seconds,"occupied_seconds"=>m.busy+held_seconds,
            "queue" => copy(m.queue), "busy_seconds" => m.busy, "down_seconds" => m.downtime,
            "utilization" => sim.time == 0 ? 0.0 : m.busy / sim.time))
    end
    jobs = [begin
        j = sim.jobs[id]
        done = j.status == "completed"
        Dict("id" => id, "status" => j.status, "operation" => done ? length(j.operations) : j.index,
            "operations" => [Dict("machine" => op.machine, "machine_group_members" => copy(op.members), "duration" => op.duration,
                "travel_before" => k == 1 ? 0.0 : travel_duration(sim, j.operations[k-1].machine, op)) for (k, op) in enumerate(j.operations)],
            "operation_count" => length(j.operations), "machine_group" => done ? nothing : j.operations[j.index].machine, "machine_group_members" => done ? String[] : copy(j.operations[j.index].members), "machine" => done ? nothing : j.status=="waiting_transport" ? j.travel_from : something(j.assigned_machine, j.operations[j.index].machine),
            "processed" => j.processed, "remaining" => done ? 0.0 : j.remaining,
            "total_remaining" => done ? 0.0 : j.remaining + sum((op.duration for op in j.operations[j.index+1:end]); init=0.0),
            "travel_from" => j.travel_from, "travel_to" => j.status in ("moving", "waiting_transport") ? something(j.assigned_machine, j.operations[j.index].machine) : nothing,
            "transporter" => j.transporter === nothing ? nothing : sim.transporters[j.transporter].id,
            "waiting_for" => j.status == "waiting_transport" ? (length(j.operations[j.index].members) > 1 && available_group_machine(sim,j) === nothing ? "machine_group" : "transporter") : nothing,
            "transport_wait_seconds" => j.transport_waited + (j.status == "waiting_transport" ? sim.time - j.transport_wait_start : 0.0),
            "travel_remaining" => j.status == "moving" ? max(0.0, j.travel_until - sim.time) : j.status == "waiting_transport" ? travel_duration(sim, j.travel_from, j.operations[j.index]) : 0.0,
            "travel_processed" => j.moved + (j.status == "moving" ? sim.time - j.travel_start : 0.0),
            "total_travel_remaining" => done ? 0.0 : (j.status == "moving" ? max(0.0, j.travel_until - sim.time) : j.status == "waiting_transport" ? travel_duration(sim, j.travel_from, j.operations[j.index]) : 0.0) +
                sum((travel_duration(sim, j.operations[k-1].machine, j.operations[k]) for k in j.index+1:length(j.operations)); init=0.0),
            "entered" => j.entered, "completed" => j.completed)
    end for id in sim.job_order]
    segments = [h for h in Iterators.flatten((sim.history,sim.holding_history)) if h["end"]>=history_since]
    for m in values(sim.machines)
        if m.active!==nothing && sim.jobs[m.active].status=="waiting_transport"
            j=sim.jobs[m.active]
            push!(segments,Dict{String,Any}("machine"=>m.id,"job"=>m.active,"operation"=>j.index-1,
                "start"=>j.transport_wait_start,"end"=>sim.time,"kind"=>"holding"))
        end
        if m.segment_start !== nothing
            push!(segments, Dict("machine" => m.id, "job" => m.active,
                "operation" => sim.jobs[m.active].index, "start" => m.segment_start, "end" => sim.time))
        end
    end
    events = [Dict("sequence" => e.sequence, "at" => e.at, "type" => e.kind,
                   "target" => e.kind == "add_job" ? e.payload.id : e.payload, "source" => e.source) for e in sim.events]
    transfers = deepcopy([t for t in sim.transfers if t["end"]>=history_since])
    for j in values(sim.jobs)
        if j.status == "moving"
            push!(transfers, Dict("job" => j.id, "from" => j.travel_from, "to" => j.assigned_machine,
                "start" => j.travel_start, "end" => sim.time, "transporter" => sim.transporters[j.transporter].id))
        end
    end
    Dict("time" => sim.time, "machines" => machines, "jobs" => jobs,
         "events" => events, "history" => segments, "log" => copy(sim.log), "faults" => deepcopy(sim.faults),
         "transfers" => transfers, "travel_times" => deepcopy(sim.travel_times), "default_travel_time" => sim.default_travel_time,
         "machine_groups" => deepcopy(sim.machine_groups), "machine_reservations" => copy(sim.machine_reservations),
         "input_info" => deepcopy(sim.input_info), "machine_count" => length(sim.machine_order), "job_count" => length(sim.reserved_ids),
         "scenario_sequence" => scenario_snapshot(sim), "warnings" => deepcopy(get(sim.input_info,"warnings",String[])),
         "transport_count" => length(sim.transporters), "transfer_queue" => copy(sim.transfer_queue),
         "transporters" => [Dict("id" => t.id, "job" => t.active, "status" => t.active === nothing ? "idle" : "moving",
             "remaining" => t.active === nothing ? 0.0 : sim.jobs[t.active].travel_until - sim.time,
             "busy_seconds" => t.busy) for t in sim.transporters])
end

include("InputData.jl")

function load_config(data::AbstractDict; transfer_selector=nothing,event_observer=nothing,advance_enabled=true)
    data = normalize_config(data)
    ids = required(data, "machines")
    ids isa AbstractVector || throw(ArgumentError("machines は配列で指定してください"))
    sim = Simulation(ids)
    sim.advance_enabled = advance_enabled
    sim.transfer_selector = transfer_selector
    sim.event_observer = event_observer
    configure_machine_groups!(sim, get(data, "machine_groups", Dict()))
    count = transport_count(get(data, "transport_count", 1))
    sim.transporters = [Transporter("T$i", nothing, 0.0) for i in 1:count]
    sim.default_travel_time = number(get(data, "default_travel_time", 0), "default_travel_time")
    raw_travel = get(data, "travel_times", Dict{String,Any}())
    raw_travel isa AbstractDict || throw(ArgumentError("travel_times は機械IDごとのオブジェクトで指定してください"))
    for (from, destinations) in raw_travel
        haskey(sim.machines, from) || throw(ArgumentError("移動元の未知の機械: $from"))
        destinations isa AbstractDict || throw(ArgumentError("travel_times[$from] はオブジェクトで指定してください"))
        sim.travel_times[from] = Dict{String,Float64}()
        for (to, duration) in destinations
            haskey(sim.machines, to) || throw(ArgumentError("移動先の未知の機械: $to"))
            sim.travel_times[from][to] = number(duration, "travel_times[$from][$to]")
        end
    end
    info = get(data, "input_info", Dict{String,Any}())
    info isa AbstractDict || throw(ArgumentError("input_info はオブジェクトで指定してください"))
    sim.input_info = Dict{String,Any}(String(k) => deepcopy(v) for (k, v) in info)
    jobs = get(data, "jobs", Any[])
    jobs isa AbstractVector || throw(ArgumentError("jobs は配列で指定してください"))
    for job in jobs
        submit!(sim, Dict("type" => "add_job", "at" => get(job, "release", 0), "job" => job); settle=false)
    end
    events = get(data, "events", Any[])
    events isa AbstractVector || throw(ArgumentError("events は配列で指定してください"))
    legacy_faults = Any[]
    for event in events
        kind, at, payload = validate_input(sim, event)
        if kind == "add_job"
            enqueue!(sim, kind, at, payload, "external")
        else
            push!(legacy_faults, Dict("type" => kind, "at" => at, "machine" => payload))
        end
    end
    raw_policy = get(data, "faults", Dict("mode" => "none"))
    raw_policy isa AbstractDict || throw(ArgumentError("faults はJSONオブジェクトで指定してください"))
    policy = Dict{String,Any}(String(k) => deepcopy(v) for (k, v) in raw_policy)
    if get(policy, "mode", "none") == "scenario"
        raw = get(policy, "events", Any[])
        raw isa AbstractVector || throw(ArgumentError("故障シナリオの events は配列で指定してください"))
        policy["events"] = vcat(raw, legacy_faults)
    end
    configure_faults!(sim, policy; settle=false)
    prepare_scenarios!(sim, get(data, "scenario_sequence", Any[]))
    advance!(sim, 0)
end

load_config(path::AbstractString) = load_config(read_config_file(path))

include("Scenarios.jl")
include("WebServer.jl")
end

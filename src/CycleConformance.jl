# Bounded online measurements. Simulation time is the only clock used here.
const CONFORMANCE_WINDOW=200
const CONFORMANCE_OBSERVATIONS=256
const CONFORMANCE_KINDS=("transport","admission","completion")
const ConformanceKey=Tuple{String,Int,Int}
Base.@kwdef mutable struct CycleConformance
    reference::Any=nothing
    generation::Int=0
    observations::Dict{ConformanceKey,Dict{Int,Float64}}=Dict{ConformanceKey,Dict{Int,Float64}}()
    samples::Dict{String,Vector{Any}}=Dict(k=>Any[] for k in CONFORMANCE_KINDS)
    totals::Dict{String,Int}=Dict(k=>0 for k in CONFORMANCE_KINDS)
    archives::Vector{Any}=Any[]
    unmapped_events::Int=0
    expired_observations::Int=0
end
cc_mean(v)=sum(v)/length(v)
cc_median(v)=let s=sort(Float64.(v));n=length(s);isodd(n) ? s[(n+1)÷2] : (s[n÷2]+s[n÷2+1])/2;end
function conformance_statistics(samples,T)
    empty=Dict{String,Any}("count"=>0,"group_count"=>0,"score_percent"=>nothing,"within_5_percent"=>nothing,
        "mean_absolute_error_percent"=>nothing,"median_period_seconds"=>nothing,"bias_percent"=>nothing,
        "jitter_percent"=>nothing,"p95_error_percent"=>nothing,"reversed_count"=>0,"groups"=>Any[])
    isempty(samples) && return empty
    groups=Dict{Tuple{Int,Int},Vector{Any}}()
    for s in samples;push!(get!(groups,(s["route_id"],s["operation"]),Any[]),s);end
    rows=Any[]
    for (key,values) in sort(collect(groups);by=first)
        intervals=[s["interval_seconds"] for s in values]
        errors=[abs(d/T-1)*100 for d in intervals];center=cc_median(intervals)
        push!(rows,Dict("route_id"=>key[1],"operation"=>key[2],"count"=>length(values),
            "median_period_seconds"=>center,"mean_absolute_error_percent"=>cc_mean(errors),
            "score_percent"=>clamp(100-cc_mean(errors),0,100),
            "within_5_percent"=>100*count(e->e<=5+1e-8,errors)/length(errors),
            "jitter_percent"=>100*cc_median(abs.(intervals.-center))/T,
            "reversed_count"=>count(<(0),intervals)))
    end
    error=cc_mean([r["mean_absolute_error_percent"] for r in rows])
    median=cc_median([r["median_period_seconds"] for r in rows])
    errors=sort([abs(s["interval_seconds"]/T-1)*100 for s in samples])
    merge(empty,Dict("count"=>length(samples),"group_count"=>length(rows),"score_percent"=>clamp(100-error,0,100),
        "within_5_percent"=>cc_mean([r["within_5_percent"] for r in rows]),"mean_absolute_error_percent"=>error,
        "median_period_seconds"=>median,"bias_percent"=>100*(median/T-1),
        "jitter_percent"=>cc_mean([r["jitter_percent"] for r in rows]),
        "p95_error_percent"=>errors[ceil(Int,0.95length(errors))],
        "reversed_count"=>sum(r["reversed_count"] for r in rows),"groups"=>rows))
end
function conformance_channels(state)
    ref=state.reference
    ref===nothing && return Dict{String,Any}()
    T=ref["period"];steady_from=ref["since"]+2T
    Dict(kind=>begin
        samples=state.samples[kind]
        steady=[s for s in samples if s["previous_at"]>=steady_from && s["next_at"]>=steady_from]
        expected=count(k->k[1]==kind,ref["expected_keys"])
        all=conformance_statistics(samples,T);stable=conformance_statistics(steady,T)
        last_time=isempty(samples) ? nothing : maximum(s["at"] for s in samples)
        Dict("all"=>all,"steady"=>stable,"total_intervals"=>state.totals[kind],"expected_groups"=>expected,
            "last_observed_at"=>last_time,"samples"=>deepcopy(samples))
    end for kind in CONFORMANCE_KINDS)
end
function archive_conformance!(state,at)
    state.reference===nothing && return
    if any(>(0),values(state.totals))
        channels=conformance_channels(state)
        for channel in values(channels);delete!(channel,"samples");end
        push!(state.archives,Dict("reference"=>deepcopy(state.reference),"ended_at"=>at,"channels"=>channels))
        length(state.archives)>30 && popfirst!(state.archives)
    end
end
function set_conformance_reference!(app,reference;record=true)
    if reference!==nothing
        reference=deepcopy(reference)
        reference["expected_keys"]=[(String(k[1]),Int(k[2]),Int(k[3])) for k in reference["expected_keys"]]
    end
    state=app.cycle_conformance
    key=r->(r["model_key"],r["period"],r["mode"])
    if state.reference!==nothing && reference!==nothing && key(state.reference)==key(reference)
        # A final result or repeated identical lot does not restart observation.
        merge!(state.reference,Dict(k=>v for (k,v) in reference if k!="since"))
        return
    end
    archive_conformance!(state,app.sim.time)
    state.generation+=1;state.reference=reference===nothing ? nothing : deepcopy(reference)
    empty!(state.observations)
    for kind in CONFORMANCE_KINDS;empty!(state.samples[kind]);state.totals[kind]=0;end
    state.unmapped_events=0;state.expired_observations=0
    record && JS.record!(app.sim,"cycle_reference_changed";reference=deepcopy(state.reference))
end
function note_conformance_reference!(app)
    cycle=app.cached_cycle===nothing ? app.best_cycle : app.cached_cycle
    cycle===nothing && return
    get(cycle,"model_key",nothing)==pattern_model_key(app) || return
    solution=cycle["solution"];keys=ConformanceKey[]
    routes=sort(unique(Int(e[1]) for e in solution["events"]))
    for r in routes;push!(keys,("admission",r,0),("completion",r,0));end
    for (i,e) in enumerate(solution["events"])
        get(solution,"is_terminal",falses(length(solution["events"])))[i] && continue
        push!(keys,("transport",Int(e[1]),Int(e[2])))
    end
    ref=Dict("period"=>Float64(solution["T"]),"since"=>app.sim.time,"request_id"=>cycle["request_id"],
        "solver"=>cycle["solver"],"status"=>cycle["status"],"model_key"=>cycle["model_key"],
        "mode"=>app.config["control"]["mode"],"used_for_dispatch"=>dispatch_policy(app)!="fifo",
        "expected_keys"=>keys)
    set_conformance_reference!(app,ref)
end
function conformance_observation!(state,kind,route,operation,instance,at,job)
    ref=state.reference;ref===nothing && return
    key=(kind,Int(route),Int(operation))
    key in ref["expected_keys"] || return
    observations=get!(state.observations,key,Dict{Int,Float64}())
    haskey(observations,instance) && return # Fault resumes and duplicates are not new cycles.
    observations[instance]=Float64(at)
    function pair(left,right)
        haskey(observations,left) && haskey(observations,right) || return
        a,b=observations[left],observations[right]
        push!(state.samples[kind],Dict("route_id"=>route,"operation"=>operation,"instance_index"=>right,
            "previous_at"=>a,"next_at"=>b,"at"=>max(a,b),"interval_seconds"=>b-a,"ratio"=>(b-a)/ref["period"],"job_id"=>job))
        state.totals[kind]+=1
        length(state.samples[kind])>CONFORMANCE_WINDOW && popfirst!(state.samples[kind])
    end
    pair(instance-1,instance);pair(instance,instance+1)
    if length(observations)>CONFORMANCE_OBSERVATIONS
        _,oldest=findmin(observations)
        delete!(observations,oldest);state.expired_observations+=1
    end
end
function observe_conformance!(app,sim,event)
    sim===app.sim || return
    if app.replay_mode
        while !isempty(app.replay_cycle_references) && first(app.replay_cycle_references)["time"]<=event["time"]
            original=popfirst!(app.replay_cycle_references)
            set_conformance_reference!(app,original["reference"];record=false)
        end
    end
    kind=event["type"]
    if kind=="transport_count_changed"
        set_conformance_reference!(app,nothing);return
    elseif kind=="optimizer_mode_changed"
        note_conformance_reference!(app);return
    end
    channel=kind in ("transfer_started","transfer_consumed") ? "transport" : kind=="job_completed" ? "completion" :
        kind in ("job_added","job_released") ? "admission" : nothing
    channel===nothing && return
    state=app.cycle_conformance;state.reference===nothing && return
    id=event["job"];m=get(app.mapping,id,nothing)
    if m===nothing;state.unmapped_events+=1;return;end
    job=get(sim.jobs,id,nothing)
    kind=="job_added" && job!==nothing && job.status=="waiting_release" && return
    operation=channel=="transport" ? get(event,"source_operation",job===nothing ? 0 : job.index-1) : 0
    conformance_observation!(state,channel,m["route_id"],operation,m["instance_index"],event["time"],id)
end
function cycle_conformance_summary(app;include_history=true)
    state=app.cycle_conformance;ref=state.reference
    Dict("available"=>ref!==nothing,"reference"=>deepcopy(ref),"generation"=>state.generation,
        "window_intervals"=>CONFORMANCE_WINDOW,"tolerance_percent"=>5.0,"warmup_cycles"=>2,
        "channels"=>conformance_channels(state),"unmapped_events"=>state.unmapped_events,
        "expired_observations"=>state.expired_observations,"previous_segment_count"=>length(state.archives),
        "previous_segments"=>include_history ? deepcopy(state.archives) : Any[],
        "simulation_time"=>app.sim.time)
end

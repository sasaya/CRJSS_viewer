function entry_state(app,e;sim=app.sim)
    id, source=e["job_id"],e["source_operation"]
    haskey(sim.jobs,id) || return "unreleased"
    j=sim.jobs[id]
    j.status=="completed" || j.index>source+1 ? "done" :
        j.index==source+1 && j.status=="moving" ? "moving" :
        j.index==source+1 && j.status=="waiting_transport" ?
            (length(j.operations[j.index].members)>1 && JS.available_group_machine(sim,j)===nothing ? "group_blocked" : "ready") :
        j.index==source+1 ? "done" : "not_ready"
end
function priority_position(app,sim,index=1)
    timing_enabled(app) && return timing_position(app,sim,index)
    candidates=findall(id -> length(sim.jobs[id].operations[sim.jobs[id].index].members)==1 ||
        JS.available_group_machine(sim,sim.jobs[id])!==nothing,sim.transfer_queue)
    isempty(candidates) && return nothing
    mode=app.config["control"]["mode"]
    mode in ("fifo","compute_only") && return first(candidates)
    key(pos) = (get(app.ranks,transfer_id(sim.transfer_queue[pos],sim.jobs[sim.transfer_queue[pos]].index-1),typemax(Int)),pos,sim.transfer_queue[pos])
    pos=candidates[argmin(key.(candidates))]
    selected=sim.transfer_queue[pos]
    token=transfer_id(selected,sim.jobs[selected].index-1)
    rank=get(app.ranks,token,typemax(Int))
    skipped=[Dict("transfer_id"=>e["transfer_id"],"rank"=>e["rank"],"reason"=>entry_state(app,e;sim))
        for e in app.entries if e["rank"]<rank && entry_state(app,e;sim) in ("unreleased","not_ready","group_blocked")]
    # One record per actual selection, never on idle polling.
    JS.record!(sim,"priority_selected";transfer_id=token,rank=rank==typemax(Int) ? nothing : rank,
        order_id=app.order_id,skipped=skipped,source_operation=sim.jobs[selected].index-1)
    pos
end

function reconcile_order(app,entries,request)
    request["experiment_epoch"]==app.epoch || throw(ArgumentError("epoch不一致"))
    request["problem_id"]==app.problem_id || throw(ArgumentError("原入力不一致"))
    request["transport_count"]==length(app.sim.transporters) || throw(ArgumentError("搬送台数不一致"))
    for m in request["mapping"]
        id=m["job_id"]
        id in app.sim.reserved_ids && haskey(app.mapping,id) && app.mapping[id]==m || throw(ArgumentError("ジョブ対応表不一致"))
    end
    # Preserve ranks of future transfers; moving and consumed tokens cannot be reassigned.
    # apply_order! freezes each retained row before sharing it with histories.
    [e for e in entries if entry_state(app,e) ∉ ("done","moving")]
end

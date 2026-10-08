# Shared by the controller and its independent solver worker.
const OPTIMIZATION_STOP_CONDITIONS=("gap","time","time_or_gap")
function termination_settings(opts)
    mode=get(opts,"stop_condition","time")
    mode in OPTIMIZATION_STOP_CONDITIONS || throw(ArgumentError("終了条件は gap、time、time_or_gap のいずれかです"))
    (seconds=mode=="gap" ? nothing : opts["solver_limit_wall_seconds"],
        relative_gap=mode=="time" ? 0.0 : strict_relative_gap(get(opts,"gap_percent",1.0)),
        gap_target_percent=mode=="time" ? nothing : get(opts,"gap_percent",1.0))
end
strict_relative_gap(percent)=percent==0 ? 0.0 : max(0.0,prevfloat(Float64(percent)/100))
function solution_gap_percent(result)
    solution=get(result,"solution",nothing);bound=get(result,"solver_bound",nothing)
    solution===nothing || bound===nothing || !isfinite(bound) ? nothing :
        max(0.0,100*(solution["T"]-bound)/max(1,abs(solution["T"])))
end
gap_target_met(gap,target)=gap!==nothing && isfinite(gap) && (target==0 ? gap==0 : gap<target)
function gap_search_must_continue(result,opts)
    get(opts,"stop_condition","time")=="gap" || return false
    result["status"] in ("INFEASIBLE","MODEL_INVALID","ERROR") && return false
    # Zero requests exact optimality; preserve the solvers' proof tolerance.
    target=get(opts,"gap_percent",1.0)
    target==0 && result["status"]=="OPTIMAL" && return false
    !gap_target_met(solution_gap_percent(result),target)
end
function solve_until_gap(search,opts;on_retry=(_,_)->nothing)
    ratio=termination_settings(opts).relative_gap;attempt=1;best=nothing;known_bound=nothing
    while true
        result=search(attempt,ratio)
        bound=get(result,"solver_bound",nothing)
        if bound!==nothing && isfinite(bound)
            known_bound=known_bound===nothing ? bound : max(known_bound,bound)
        end
        solution=get(result,"solution",nothing)
        if best!==nothing && (solution===nothing || best["solution"]["T"]<solution["T"])
            result["solution"]=deepcopy(best["solution"])
            haskey(best,"verification") && (result["verification"]=deepcopy(best["verification"]))
            result["status"]=="UNKNOWN" && (result["status"]="FEASIBLE")
        end
        if get(result,"solution",nothing)!==nothing
            known_bound!==nothing && (result["solver_bound"]=known_bound)
            result["status"]=="OPTIMAL" && known_bound!==nothing && result["solution"]["T"]-known_bound>1e-5 && (result["status"]="FEASIBLE")
            best=result
        end
        result["search_attempts"]=attempt
        gap_search_must_continue(result,opts) || return result
        on_retry(result,attempt)
        # Some engines stop on an inclusive/tolerant boundary. Tighten and
        # continue the same request, retaining its verified best solution.
        ratio/=2;attempt+=1
    end
end
request_deadline_expired(opts,elapsed)=get(opts,"stop_condition","time")!="gap" && elapsed>opts["request_limit_wall_seconds"]
function optimization_termination_reason(result,opts,actual_gap)
    result["status"]=="OPTIMAL" && return "optimal"
    result["status"]=="INFEASIBLE" && return "infeasible"
    limits=termination_settings(opts)
    limits.gap_target_percent!==nothing && gap_target_met(actual_gap,limits.gap_target_percent) && return "gap_reached"
    limits.seconds!==nothing ? "time_limit" : "solver_stopped"
end

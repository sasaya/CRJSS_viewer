"""
    build_model(problem; hoists=1, upper=10000, target=nothing)

数式の中心となるファイルです。まず元のMILPの変数・制約を作り、
最後にCP-SATが資源の競合を発見しやすくなる補助制約を追加します。
"""
function build_model(p::HoistProblem;hoists=1,upper=10000,target=nothing,strengthen=true)
    hoists>=1 || error("ホイストは1台以上にしてください")
    lower=analytic_lower_bound(p,hoists)
    model=Model(); extras=CPExtras()
    n=length(p.events); M=10000
    @variable(model, lower <= T <= upper, Int)
    @variable(model, 0 <= s[1:n] <= upper, Int)
    @constraint(model,[a in 1:n],s[a]<=T)
    !isnothing(target) && @constraint(model,T==target)

    # s[a]: 搬送なら開始時刻、終端なら自動排出される時刻（一周期内の位相）。
    # y[a,b]=1 は、aがbより先という意味です。逆向きは1-yで表します。
    y=Matrix{Any}(undef,n,n)
    for a in 1:n
        y[a,a]=@variable(model,binary=true,base_name="self_$a")
        for b in a+1:n
            y[a,b]=@variable(model,binary=true,base_name="before_$(a)_$b")
            y[b,a]=1-y[a,b]
            @constraint(model,s[b]-s[a]>=-upper*(1-y[a,b]))
            @constraint(model,s[a]-s[b]>=-upper*y[a,b])
        end
    end
    @constraint(model,s[1]==0)
    @constraint(model,hoists*T>=sum(p.duration))

    # 終端は自動排出なので、ホイストの割当変数xを持ちません。
    x=Dict((a,h)=>@variable(model,binary=true,base_name="hoist_$(a)_$h")
           for a in p.moves for h in 1:hoists)
    for a in p.moves
        @constraint(model,sum(x[a,h] for h in 1:hoists)==1)
        @constraint(model,T>=s[a]+p.duration[a]+p.travel[p.destination[a],1])
    end
    @constraint(model,x[first(p.moves),1]==1) # 同一性能のホイストのラベル対称性を除く。

    for a in p.moves, b in p.moves
        a==b && continue
        for h in 1:hoists
            @constraint(model,s[b]-s[a]>=p.duration[a]+p.travel[p.destination[a],p.source[b]]-
                        M*(3-y[a,b]-x[a,h]-x[b,h]))
            @constraint(model,s[b]-s[a]>=5-M*(3-y[a,b]-x[a,h]-(1-x[b,h])))
        end
    end

    # z[a,k]: 処理aが使用する周期数の選択。ell[a]が実際の周期の跨ぎ数です。
    z=Dict{Tuple{Int,Int},VariableRef}()
    ell=Dict{Int,Any}()
    for a in 1:n
        b=p.previous[a]
        b==0 && continue
        choices=VariableRef[]
        for k in 1:p.capacity[p.source[a]]
            z[a,k]=@variable(model,binary=true,base_name="cycle_$(a)_$k")
            push!(choices,z[a,k])
            dwell=s[a]-s[b]-p.duration[b]+(k-1)*T
            @constraint(model,dwell>=p.minimum_dwell[a]-M*(2-y[b,a]-z[a,k]))
            @constraint(model,dwell<=p.maximum_dwell[a]+M*(2-y[b,a]-z[a,k]))
            @constraint(model,dwell+T>=p.minimum_dwell[a]-M*(1+y[b,a]-z[a,k]))
            @constraint(model,dwell+T<=p.maximum_dwell[a]+M*(1+y[b,a]-z[a,k]))
        end
        @constraint(model,sum(choices)==1)
        ell[a]=sum((k-1)*z[a,k] for k in 1:p.capacity[p.source[a]])+y[a,b]
    end

    # 槽の予約は搬入開始から処理終了までです。終端のStation1もここに含みます。
    # 自動排出が終われば、その枠を別の品物の搬入に使用できます。
    for (w,group) in p.groups
        @constraint(model,sum((ell[a] for a in group);init=0)<=p.capacity[w])
        for a in group
            b=p.previous[a]
            @constraint(model,sum(ell[c]-y[c,b] for c in group)+
                sum((y[p.previous[c],b] for c in group if c!=a);init=0)<=p.capacity[w]-1)
            for c in group
                if a!=c && p.events[a][1]>=2 && p.events[c][1]>=2 && p.capacity[w]<=1
                    @constraint(model,y[b,a]+y[p.previous[c],c]+y[a,p.previous[c]]+y[c,b]==3)
                end
            end
        end
    end

    # HiGHSで元の線形式を比較するときは、ここまでのモデルを使います。
    if !strengthen
        @objective(model,Min,T)
        return model,extras,(T=T,s=s,y=y,z=z,x=x),lower
    end
    # ここからはCP-SAT用の補強です。排出イベントには搬送区間を作りません。
    for h in 1:hoists
        group=Int[]
        for a in p.moves
            push!(group,add_interval!(extras,s[a],p.duration[a],s[a]+p.duration[a];presence=x[a,h]))
        end
        push!(extras.no_overlaps,group)
    end
    # 正の搬送を1つの巡回路として結び、空移動を含む周期下界も与えます。
    if hoists==1 && p.source[1]==1 && length(p.moves)>1
        edges=[]; total_travel=AffExpr(0.0)
        for (ia,a) in enumerate(p.moves), (ib,b) in enumerate(p.moves)
            ia==ib && continue
            arc=@variable(model,binary=true,base_name="arc_$(a)_$b")
            push!(edges,(ia,ib,arc))
            gap=p.duration[a]+p.travel[p.destination[a],p.source[b]]
            add_to_expression!(total_travel,gap,arc)
            if ib==1
                only_if!(extras,@constraint(model,T>=s[a]+gap),[(arc,true)])
            else
                only_if!(extras,@constraint(model,s[b]>=s[a]+gap),[(arc,true)])
            end
        end
        push!(extras.circuits,edges)
        @constraint(model,T>=total_travel)
    end

    # 周期を複数個展開し、どの時刻でも予約数が槽容量を超えないようにします。
    # 条件付き等式には順序yの肯定/否定を渡す必要があるため補助関数を用います。
    order_literal(a,b)=a<b ? (y[a,b],true) : (y[b,a],false)
    for (w,group) in p.groups
        isempty(group) && continue
        intervals=Int[]
        extend=hoists==1 && all(!p.terminal[a] && p.source[p.previous[a]]!=w for a in group)
        early=extend && all(p.destination[a]==1 for a in group) && p.source[1]==1
        for a in group
            b=p.previous[a]
            before=early ? p.travel[1,p.source[b]] : 0
            extra=(extend ? p.duration[a] : 0)+before
            reserve_length=@variable(model,lower_bound=0,upper_bound=(p.capacity[w]+1)*upper,integer=true)
            for k in 1:p.capacity[w]
                only_if!(extras,@constraint(model,reserve_length==s[a]-s[b]+(k-1)*T+extra),
                         [(z[a,k],true),order_literal(b,a)])
                only_if!(extras,@constraint(model,reserve_length==s[a]-s[b]+k*T+extra),
                         [(z[a,k],true),order_literal(a,b)])
            end
            for shift in -p.capacity[w]:1
                begin_time=@variable(model,lower_bound=-(p.capacity[w]+1)*upper,upper_bound=2upper,integer=true)
                end_time=@variable(model,lower_bound=-(p.capacity[w]+1)*upper,upper_bound=(p.capacity[w]+3)*upper,integer=true)
                @constraint(model,begin_time==s[b]-before+shift*T)
                @constraint(model,end_time==begin_time+reserve_length)
                push!(intervals,add_interval!(extras,begin_time,reserve_length,end_time))
            end
        end
        push!(extras.cumulative,(intervals,p.capacity[w]))
    end
    @objective(model,Min,T)
    return model,extras,(T=T,s=s,y=y,z=z,x=x),lower
end

"""以前のJSON解から、同じ品種・工程に対応する変数だけを初期値にします。"""
function apply_hint!(p,vars,path)
    old=JSON.parsefile(path)
    sol=get(old,"solution",nothing)
    isnothing(sol) && return
    events=get(sol,"events",get(sol,"jobs",nothing))
    isnothing(events) && error("ヒントに工程の番号がありません")
    index=Dict(Tuple(a)=>i for (i,a) in enumerate(events))
    set_start_value(vars.T,sol["T"])
    for (a,event) in enumerate(p.events)
        haskey(index,event) || continue
        i=index[event]
        set_start_value(vars.s[a],sol["starts"][i])
        if a in p.moves && haskey(sol,"hoists") && !isnothing(sol["hoists"][i])
            for ((b,h),v) in vars.x
                b==a && set_start_value(v,Int(h==sol["hoists"][i]+1))
            end
        end
        for ((b,k),v) in vars.z
            b==a && set_start_value(v,Int(k==sol["k"][i]))
        end
        set_start_value(vars.y[a,a],sol["y"][i][i])
        for b in a+1:length(p.events)
            haskey(index,p.events[b]) || continue
            set_start_value(vars.y[a,b],sol["y"][i][index[p.events[b]]])
        end
    end
end

function solve_problem(p::HoistProblem;hoists=1,seconds=120.0,workers=8,seed=1,
                       upper=10000,target=nothing,hint=nothing,output=nothing,log=false,on_phase=(_->nothing),relative_gap=0.0)
    on_phase("building_model")
    model,extras,vars,lower=build_model(p;hoists,upper,target)
    !isnothing(hint) && apply_hint!(p,vars,hint)
    on_phase("solving")
    response,ids=run_native_cp(model,extras;seconds,workers,seed,log,relative_gap)
    on_phase("validating")
    return result_from_response(p,vars,ids,response;hoists,seconds,workers,seed,upper,target,output,lower)
end

"""Solve the original linear integer formulation with the bundled HiGHS library."""
function solve_highs(p::HoistProblem;hoists=1,seconds=120.0,workers=1,seed=1,
                     upper=10000,on_phase=(_->nothing),relative_gap=0.0,on_incumbent=nothing)
    on_phase("building_model")
    model,_,vars,lower=build_model(p;hoists,upper,strengthen=false)
    set_optimizer(model,HiGHS.Optimizer)
    set_silent(model)
    seconds!==nothing && set_time_limit_sec(model,Float64(seconds))
    set_optimizer_attribute(model,"threads",workers)
    set_optimizer_attribute(model,"random_seed",seed)
    set_optimizer_attribute(model,"mip_rel_gap",Float64(relative_gap))
    set_optimizer_attribute(model,"mip_abs_gap",0.0)
    if on_incumbent!==nothing
        best=Ref(Inf)
        columns=Dict{VariableRef,Int}()
        function observer(kind::Cint,::Ptr{Cchar},data::HiGHS.HighsCallbackDataOut)::Cint
            if kind==HiGHS.kHighsCallbackMipImprovingSolution && data.mip_solution!=C_NULL && isfinite(data.mip_primal_bound) && data.mip_primal_bound<best[]
                values=copy(unsafe_wrap(Vector{Cdouble},data.mip_solution,Int(data.mip_solution_size)))
                val(v::VariableRef)=round(Int,values[columns[v]])
                val(e)=JuMP.value(val,e)
                solution=Dict{String,Any}("T"=>val(vars.T),"events"=>collect.(p.events),"is_terminal"=>collect(p.terminal),
                    "starts"=>[val(v) for v in vars.s],
                    "hoists"=>[p.terminal[a] ? nothing : findfirst(h->val(vars.x[a,h])==1,1:hoists)-1 for a in eachindex(p.events)],
                    "y"=>[[val(vars.y[a,b]) for b in eachindex(p.events)] for a in eachindex(p.events)],
                    "k"=>[p.previous[a]==0 ? 1 : findfirst(k->val(vars.z[a,k])==1,1:p.capacity[p.source[a]]) for a in eachindex(p.events)])
                incumbent=Dict{String,Any}("solution"=>solution,"hoist_count"=>hoists,"analytic_lower_bound"=>lower,
                    "solver_bound"=>isfinite(data.mip_dual_bound) ? data.mip_dual_bound : lower,"status"=>"FEASIBLE","solver"=>"highs")
                incumbent["verification"]=verify_result(p,incumbent)
                incumbent["verification"]["valid"] || error("HiGHS incumbent failed verification")
                solution["T"]>=best[] && return Cint(0)
                best[]=solution["T"]
                on_incumbent(incumbent,data.running_time)
            end
            Cint(0)
        end
        set_attribute(model,HiGHS.CallbackFunction([HiGHS.kHighsCallbackMipImprovingSolution]),observer)
        MOI.Utilities.attach_optimizer(backend(model))
        native=unsafe_backend(model)
        for v in all_variables(model);columns[v]=HiGHS.column(native,optimizer_index(v))+1;end
    end
    on_phase("solving")
    optimize!(model)
    termination=termination_status(model)
    feasible=primal_status(model)==MOI.FEASIBLE_POINT
    status=termination==MOI.OPTIMAL ? "OPTIMAL" : feasible ? "FEASIBLE" :
        termination==MOI.INFEASIBLE ? "INFEASIBLE" : "UNKNOWN"
    bound=objective_bound(model)
    feasible && status=="OPTIMAL" && isfinite(bound) && objective_value(model)-bound>1e-5 && (status="FEASIBLE")
    result=Dict{String,Any}("method"=>"Julia / HiGHS MILP","solver"=>"highs","status"=>status,
        "model_semantics"=>"automatic_terminal_discharge","hoist_count"=>hoists,
        "move_count"=>length(p.moves),"terminal_count"=>count(p.terminal),
        "analytic_lower_bound"=>lower,"solver_bound"=>isfinite(bound) ? bound : nothing,
        "solve_seconds"=>solve_time(model),"time_limit"=>seconds,"workers"=>workers,
        "seed"=>seed,"upper"=>upper,"target"=>nothing,"solution"=>nothing,
        "solver_message"=>string(termination))
    on_phase("validating")
    if feasible
        function val(v::VariableRef)
            x=value(v)
            abs(x-round(x))<=1e-5 || error("HiGHS returned a nonintegral value: $x")
            round(Int,x)
        end
        val(e)=JuMP.value(val,e)
        result["solution"]=Dict{String,Any}("T"=>val(vars.T),"events"=>collect.(p.events),
            "is_terminal"=>collect(p.terminal),"starts"=>[val(v) for v in vars.s],
            "hoists"=>[p.terminal[a] ? nothing : findfirst(h->val(vars.x[a,h])==1,1:hoists)-1 for a in eachindex(p.events)],
            "y"=>[[val(vars.y[a,b]) for b in eachindex(p.events)] for a in eachindex(p.events)],
            "k"=>[p.previous[a]==0 ? 1 : findfirst(k->val(vars.z[a,k])==1,1:p.capacity[p.source[a]]) for a in eachindex(p.events)])
        result["verification"]=verify_result(p,result)
        result["verification"]["valid"] || error("HiGHS solution failed numerical verification")
    end
    result
end

# 最終解と途中の改善解を同じ方法で変換・検証するため、共通の関数にしています。
function result_from_response(p,vars,ids,response;hoists,seconds,workers,seed,upper,target,
                              output=nothing,lower=analytic_lower_bound(p,hoists))
    status=string(response.status)
    status=="OPTIMAL" && response.objective_value-response.best_objective_bound>1e-5 && (status="FEASIBLE")
    result=Dict{String,Any}("method"=>"Julia / ORTools.jl CP-SAT", "status"=>status,
        "model_semantics"=>"automatic_terminal_discharge", "hoist_count"=>hoists,
        "move_count"=>length(p.moves),"terminal_count"=>count(p.terminal),
        "analytic_lower_bound"=>lower,"solver_bound"=>response.best_objective_bound,
        "solve_seconds"=>response.wall_time,"time_limit"=>seconds,"workers"=>workers,
        "seed"=>seed,"upper"=>upper,"target"=>target,"solution"=>nothing,
        "solver_message"=>response.solution_info)
    if status in ("OPTIMAL","FEASIBLE")
        val(v::VariableRef)=response.solution[ids[v]+1]
        val(e)=JuMP.value(val,e)
        solution=Dict{String,Any}("T"=>val(vars.T),"events"=>collect.(p.events),
            "is_terminal"=>collect(p.terminal),"starts"=>[val(v) for v in vars.s],
            "hoists"=>[p.terminal[a] ? nothing : findfirst(h->val(vars.x[a,h])==1,1:hoists)-1 for a in eachindex(p.events)],
            "y"=>[[val(vars.y[a,b]) for b in eachindex(p.events)] for a in eachindex(p.events)],
            "k"=>[p.previous[a]==0 ? 1 : findfirst(k->val(vars.z[a,k])==1,1:p.capacity[p.source[a]]) for a in eachindex(p.events)])
        result["solution"]=solution
        result["verification"]=verify_result(p,result)
        result["verification"]["valid"] || error("検証不合格: $(result["verification"])")
    end
    if !isnothing(output)
        mkpath(dirname(abspath(output)))
        open(output,"w") do io
            JSON.print(io,result,2)
        end
    end
    return result
end

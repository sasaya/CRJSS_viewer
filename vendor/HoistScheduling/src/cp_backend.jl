# このファイルだけが OR-Tools の低水準APIを知っています。
# モデル本体は普通のJuMP式で書き、ここでCP-SATの整数式に変換します。
# Pythonの実行・PythonCall・外部Python環境は一切使用しません。

function prepare_ortools_library()
    if Sys.iswindows()
        # ORTools_jll 9.15 のWindows配布には、bz2-1.dllという依存名と
        # libbz2.dllという実ファイル名の不一致があります。ローカルに別名を作ります。
        package_root=dirname(dirname(Base.find_package("ORTools_jll")))
        toml=joinpath(package_root,"Artifacts.toml")
        hash=Pkg.Artifacts.artifact_hash("ORTools",toml)
        artifact=Pkg.Artifacts.artifact_path(hash)
        runtime=joinpath(@__DIR__,"..","..","..","runtime","windows_runtime")
        mkpath(runtime)
        alias=joinpath(runtime,"bz2-1.dll")
        isfile(alias) || cp(joinpath(artifact,"bin","libbz2.dll"),alias)
        Libdl.dlopen(alias)
    end
end
prepare_ortools_library()
using ORTools, ORTools_jll
ORTools.set_library(ORTools_jll.libortools)

"""JuMPモデルと、CP-SAT専用の補助制約をひとまとめに保持します。"""
mutable struct CPExtras
    # 条件付き制約: [(二値変数, その変数がtrue/false), ...] が全部成立すると有効。
    conditions::Dict{Any,Vector{Tuple{VariableRef,Bool}}}
    intervals::Vector{Any}
    no_overlaps::Vector{Vector{Int}}
    cumulative::Vector{Tuple{Vector{Int},Int}}
    circuits::Vector{Any}
end
CPExtras()=CPExtras(Dict(),[],[],[],[])

function only_if!(extras, constraint, literals)
    extras.conditions[constraint]=collect(literals)
    return constraint
end

function add_interval!(extras, start, duration, finish; presence=nothing)
    push!(extras.intervals,(start=start,duration=duration,finish=finish,presence=presence))
    return length(extras.intervals)
end

"""JuMPの一次式 → OR-Toolsの一次式。係数の丸めでモデルを変えないよう検査します。"""
function cp_expression(expression, ids)
    expression=convert(AffExpr,expression)
    variables=Int32[]; coefficients=Int64[]
    for (coefficient, variable) in linear_terms(expression)
        isinteger(coefficient) || error("CP-SATの係数は整数にしてください")
        push!(variables,ids[variable]); push!(coefficients,Int64(coefficient))
    end
    isinteger(constant(expression)) || error("CP-SATの定数は整数にしてください")
    return ORTools.CPSatLinearExpression(vars=variables,coeffs=coefficients,offset=Int64(constant(expression)))
end

function compile_cp(model, extras)
    cp=ORTools.CpModel(name="Cyclic hoist scheduling")
    variables=all_variables(model)
    # Juliaは1始まり、OR-Toolsの内部番号は0始まりです。
    ids=Dict(v=>Int32(i-1) for (i,v) in enumerate(variables))
    for v in variables
        lo=is_binary(v) ? 0 : lower_bound(v)
        hi=is_binary(v) ? 1 : upper_bound(v)
        native=ORTools.IntegerVariable(Int64[lo,hi]); native.name=name(v)
        push!(cp.variables,native)
    end
    literal(v,positive=true)=positive ? ids[v] : -ids[v]-1

    for c in all_constraints(model;include_variable_in_set_constraints=false)
        object=constraint_object(c)
        expression=cp_expression(object.func,ids)
        set=object.set
        # CP-SATは「下限 ≤ 一次式 ≤ 上限」の一種類で線形制約を表せます。
        lo=set isa MOI.GreaterThan ? Int64(set.lower)-expression.offset :
           set isa MOI.EqualTo ? Int64(set.value)-expression.offset : typemin(Int64)
        hi=set isa MOI.LessThan ? Int64(set.upper)-expression.offset :
           set isa MOI.EqualTo ? Int64(set.value)-expression.offset : typemax(Int64)
        linear=ORTools.CPSatLinearConstraintProto(expression.vars,expression.coeffs,Int64[lo,hi])
        active=Int32[literal(v,b) for (v,b) in get(extras.conditions,c,Tuple{VariableRef,Bool}[])]
        push!(cp.constraints,ORTools.CPSATConstraint(enforcement_literal=active,constraint=(linear=linear,)))
    end

    interval_ids=Int32[]
    for interval in extras.intervals
        native=ORTools.IntervalConstraint()
        native.start=cp_expression(interval.start,ids)
        native.size=cp_expression(interval.duration,ids)
        native.end_=cp_expression(interval.finish,ids)
        active=isnothing(interval.presence) ? Int32[] : Int32[literal(interval.presence)]
        push!(interval_ids,Int32(length(cp.constraints)))
        push!(cp.constraints,ORTools.CPSATConstraint(enforcement_literal=active,constraint=(interval=native,)))
    end
    for group in extras.no_overlaps
        native=ORTools.NoOverlapConstraintProto(interval_ids[group])
        push!(cp.constraints,ORTools.CPSATConstraint(constraint=(no_overlap=native,)))
    end
    for (group,capacity) in extras.cumulative
        native=ORTools.CumulativeConstraint()
        native.capacity=cp_expression(capacity,ids)
        native.intervals=interval_ids[group]
        native.demands=[cp_expression(1,ids) for _ in group]
        push!(cp.constraints,ORTools.CPSATConstraint(constraint=(cumulative=native,)))
    end
    for edges in extras.circuits
        native=ORTools.CircuitConstraintProto(Int32[a-1 for (a,b,v) in edges],
                    Int32[b-1 for (a,b,v) in edges],Int32[literal(v) for (a,b,v) in edges])
        push!(cp.constraints,ORTools.CPSATConstraint(constraint=(circuit=native,)))
    end
    objective=cp_expression(objective_function(model),ids)
    cp.objective=ORTools.CpObjective(vars=objective.vars,coeffs=objective.coeffs,
                                   offset=Float64(objective.offset),scaling_factor=1.0)
    hint=ORTools.NewCPSATPartialVariableAssignment()
    for v in variables
        isnothing(start_value(v)) && continue
        push!(hint.vars,ids[v]); push!(hint.values,round(Int64,start_value(v)))
    end
    !isempty(hint.vars) && (cp.solution_hint=hint)
    return cp,ids
end

"""ネイティブのCP-SATを呼び、結果をJuliaの構造体に戻します。"""
function run_native_cp(model,extras;seconds=120.0,workers=8,seed=1,log=false,relative_gap=0.0)
    cp,ids=compile_cp(model,extras)
    parameters=ORTools.SatParameters()
    seconds!==nothing && (parameters.max_time_in_seconds=Float64(seconds))
    parameters.relative_gap_limit=Float64(relative_gap)
    parameters.absolute_gap_limit=0.0
    parameters.num_search_workers=Int32(workers)
    parameters.random_seed=Int32(seed)
    parameters.log_search_progress=log
    encode(x)=begin
        io=IOBuffer()
        ORTools.PB.encode(ORTools.PB.ProtoEncoder(io),ORTools.to_proto_struct(x))
        take!(io)
    end
    request=encode(cp); settings=encode(parameters)
    response_pointer=Ref{Ptr{Cvoid}}(C_NULL); response_length=Ref{Cint}(0)
    ORTools.SolveCpModelWithParameters(request,length(request),settings,length(settings),response_pointer,response_length)
    # 応答をJuliaのメモリーへコピーしてから、C側の領域を解放します。
    response=copy(unsafe_wrap(Vector{UInt8},Ptr{UInt8}(response_pointer[]),Int(response_length[])))
    Libc.free(response_pointer[])
    parsed=ORTools.PB.decode(ORTools.PB.ProtoDecoder(IOBuffer(response)),ORTools.CpSolverResponse)
    return parsed,ids
end

"""
入力を扱う構造体。添字はすべて Julia と同じ1始まりです。
N[r]は終端処理を含む経路長です。VのN[r]+1行目は終端確認用の数値です。

`events` には搬送開始と自動排出時刻の両方を入れます。
`moves` は本当にホイストが動くものだけです。
例: 1→4→20→1→1 は、3搬送と、Station1での終端処理1件です。
"""
struct HoistProblem
    raw::Dict{String,Any}
    events::Vector{Tuple{Int,Int}}
    moves::Vector{Int}
    terminal::BitVector
    source::Vector{Int}
    destination::Vector{Int}
    duration::Vector{Int}
    minimum_dwell::Vector{Int}
    maximum_dwell::Vector{Int}
    previous::Vector{Int}
    capacity::Dict{Int,Int}
    travel::Matrix{Int}
    groups::Dict{Int,Vector{Int}}
end

function read_problem(path::AbstractString)
    raw = JSON.parsefile(path; dicttype=Dict{String,Any})
    return problem_from_dict(raw)
end

function problem_from_dict(raw)
    events = Tuple{Int,Int}[]
    terminal = BitVector()
    source, destination, duration = Int[], Int[], Int[]
    lo, hi, previous = Int[], Int[], Int[]
    stations = maximum(raw["W"]) + 1
    travel = haskey(raw,"E") ? Int.(permutedims(hcat(raw["E"]...))) :
             [2abs(a-b) for a in 1:stations, b in 1:stations]
    capacity = Dict(Int(w)=>Int(get(raw["Capacity"],string(w),1)) for w in raw["W"])

    for r in 1:raw["R"]
        preceding = 0
        for i in 1:raw["N"][r]
            from, to = Int(raw["V"][i][r]), Int(raw["V"][i+1][r])
            is_terminal = from == to
            i == 1 && is_terminal && error("品種$r に実行する搬送がありません")
            is_terminal && i!=raw["N"][r] && error("品種$r は工程$i で終端ですが、経路長N=$(raw["N"][r])と一致しません")
            i==raw["N"][r] && !is_terminal && error("品種$r の終端確認値V[N+1]はV[N]と同じにしてください")
            push!(events,(r,i)); push!(terminal,is_terminal)
            push!(source,from); push!(destination,to)
            # 終端は移動しません。ただし、その槽での処理時間L～Uは残します。
            d = is_terminal ? 0 : haskey(raw,"D") ? Int(raw["D"][i][r]) : 20+travel[from,to]
            push!(duration,d)
            push!(lo,Int(raw["L"][i][r])); push!(hi,Int(raw["U"][i][r]))
            push!(previous,preceding)
            preceding = length(events)
            is_terminal && break   # N番目の処理は残し、N+1番目以降は処理として読みません。
        end
    end
    all(v->v>=1,values(capacity)) || error("槽容量は1以上にしてください")
    all(duration .>= 0) || error("搬送時間は非負にしてください")
    for a in eachindex(events)
        previous[a] == 0 && continue
        0 <= lo[a] <= hi[a] || error("処理時間の上下限が不正です: $(events[a])")
    end
    moves = findall(.!terminal)
    groups = Dict(w=>[a for a in eachindex(events) if previous[a]>0 && source[a]==w]
                  for w in keys(capacity))
    return HoistProblem(raw,events,moves,terminal,source,destination,duration,
                        lo,hi,previous,capacity,travel,groups)
end

"""槽の必要占有量から、周期Tの下界を計算します。"""
function analytic_lower_bound(p::HoistProblem, hoists)
    bound = maximum(p.duration[a]+p.travel[p.destination[a],1] for a in p.moves)
    for a in eachindex(p.events)
        b=p.previous[a]
        b==0 && continue
        # 自動排出はホイストを拘束しないので、搬出時間を使う下界から除きます。
        if !p.terminal[a] && p.capacity[p.source[a]]==1
            gap=p.duration[a]+p.travel[p.destination[a],p.source[b]]
            hoists>1 && (gap=min(gap,5))
            bound=max(bound,p.minimum_dwell[a]+p.duration[b]+
                      min(p.duration[a]+p.travel[p.destination[a],1],gap))
        end
    end
    for (w,group) in p.groups
        isempty(group) && continue
        required=sum(p.minimum_dwell[a]+p.duration[p.previous[a]] for a in group)
        bound=max(bound,cld(required,p.capacity[w]))
        # ホイスト1台で、搬出が全て実搬送の場合だけ使える強化です。
        extend=hoists==1 && all(!p.terminal[a] && p.source[p.previous[a]]!=w for a in group)
        if extend
            required+=sum(p.duration[a] for a in group)
            if all(p.destination[a]==1 for a in group) && p.source[1]==1
                required+=sum(p.travel[1,p.source[p.previous[a]]] for a in group)
            end
            bound=max(bound,cld(required,p.capacity[w]))
        end
    end
    return bound
end

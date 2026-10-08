"""
最適化ソルバーとは別に、保存する解へ数値を代入して検証します。
終端の自動排出にはホイスト移動制約を掛けませんが、処理時間と容量は検査します。
"""
function verify_result(p::HoistProblem,result; tolerance=1e-5)
    sol=result["solution"]
    isnothing(sol) && return Dict("valid"=>false,"errors"=>["解がありません"])
    sol["events"]==collect.(p.events) || return Dict("valid"=>false,"errors"=>["工程番号が一致しません"])
    T=sol["T"]; s=sol["starts"]; k=sol["k"]; y=sol["y"]; h=sol["hoists"]
    n=length(p.events); checks=0; violation=0.0; errors=Any[]
    function check(residual,label)
        checks+=1
        violation=max(violation,Float64(residual))
        residual>tolerance && push!(errors,(label,residual))
    end
    check(abs(s[1]),"最初の搬送時刻")
    for a in 1:n
        check(-s[a],"時刻の下限"); check(s[a]-T,"時刻の上限")
        check(k[a] in 1:p.capacity[p.source[a]] ? 0 : 1,"kの範囲")
        for b in 1:n
            check(y[a][b] in (0,1) ? 0 : 1,"順序の二値性")
            a==b && continue
            check(abs(y[a][b]+y[b][a]-1),"順序の整合性")
            y[a][b]==1 && check(s[a]-s[b],"時刻の順序")
        end
    end
    for a in p.moves
        check(h[a] in 0:result["hoist_count"]-1 ? 0 : 1,"ホイストの範囲")
        check(s[a]+p.duration[a]+p.travel[p.destination[a],1]-T,"周期内の帰還")
        for b in p.moves
            a==b && continue
            for resource in 0:result["hoist_count"]-1
                xa,xb=Int(h[a]==resource),Int(h[b]==resource)
                check(p.duration[a]+p.travel[p.destination[a],p.source[b]]-
                      10000*(3-y[a][b]-xa-xb)-s[b]+s[a],"同一ホイスト")
                check(5-10000*(3-y[a][b]-xa-(1-xb))-s[b]+s[a],"異なるホイスト")
            end
        end
    end
    ell=zeros(Int,n)
    for a in 1:n
        b=p.previous[a]; b==0 && continue
        ell[a]=k[a]-1+y[a][b]
        actual=s[a]-s[b]-p.duration[b]+ell[a]*T
        check(p.minimum_dwell[a]-actual,"処理時間の下限 $(p.events[a])")
        check(actual-p.maximum_dwell[a],"処理時間の上限 $(p.events[a])")
        for kk in 1:p.capacity[p.source[a]]
            z=Int(kk==k[a]); expression=s[a]-s[b]-p.duration[b]+(kk-1)*T
            check(p.minimum_dwell[a]-10000*(2-y[b][a]-z)-expression,"5.16")
            check(expression-p.maximum_dwell[a]-10000*(2-y[b][a]-z),"5.17")
            check(p.minimum_dwell[a]-10000*(1+y[b][a]-z)-expression-T,"5.18")
            check(expression+T-p.maximum_dwell[a]-10000*(1+y[b][a]-z),"5.19")
        end
    end
    for (w,group) in p.groups
        check(sum(ell[group])-p.capacity[w],"5.22 槽$w")
        for a in group
            b=p.previous[a]
            lhs=sum(ell[c]-y[c][b] for c in group)+sum((y[p.previous[c]][b] for c in group if c!=a);init=0)
            check(lhs-p.capacity[w]+1,"5.26 槽$w")
            for c in group
                if a!=c && p.events[a][1]>=2 && p.events[c][1]>=2 && p.capacity[w]<=1
                    check(abs(y[b][a]+y[p.previous[c]][c]+y[a][p.previous[c]]+y[c][b]-3),"5.27")
                end
            end
        end
        # 順序式とは別に、周期予約区間を実際に数えて槽容量を検査します。
        intervals=Tuple{Float64,Float64}[]
        for a in group
            begin_time=s[p.previous[a]]; end_time=s[a]+ell[a]*T
            for shift in -p.capacity[w]-1:1
                left=max(0,begin_time+shift*T); right=min(T,end_time+shift*T)
                right>left+tolerance && push!(intervals,(left,right))
            end
        end
        points=sort!(unique(vcat([0.0,Float64(T)],[x for interval in intervals for x in interval])))
        for i in 1:length(points)-1
            t=(points[i]+points[i+1])/2
            check(count(pair->pair[1]<=t<pair[2],intervals)-p.capacity[w],"実時間での槽$w の容量")
        end
    end
    return Dict("valid"=>isempty(errors),"checked"=>checks,"max_violation"=>violation,
                "tolerance"=>tolerance,"errors"=>errors)
end

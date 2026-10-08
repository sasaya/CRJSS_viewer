# Shared by the server and the independent native solver worker.
transfer_id(id, source) = "$id:$source-$(source+1)"

function extract_order(solution,mapping)
    events=solution["events"];T=solution["T"];isfinite(T)&&T>0||throw(ArgumentError("周期Tが不正です"))
    previous=Dict{Int,Int}();q=zeros(Int,length(events))
    for (a,event) in enumerate(events)
        r,i=Int.(event);b=get(previous,r,0)
        b!=0&&(q[a]=q[b]+solution["k"][a]-1+solution["y"][a][b]);previous[r]=a
    end
    jobs=sort(collect(mapping);by=m->(m["route_id"],m["instance_index"],m["job_id"]))
    chains=Any[]
    for m in jobs
        chain=Any[];r=m["route_id"];n=m["instance_index"]-1
        for (a,event) in enumerate(events)
            event[1]==r && event[2]<m["operation_count"] || continue
            get(solution,"is_terminal",falses(length(events)))[a]&&continue
            push!(chain,(reference=solution["starts"][a]+(n+q[a])*T,event=a,route=r,
                instance=n,source=Int(event[2]),job=m["job_id"]))
        end
        sort!(chain;by=e->e.source);push!(chains,chain)
    end
    heads=ones(Int,length(jobs));heap=Tuple{Float64,Int}[]
    function pushhead(j)
        heads[j]>length(chains[j])&&return
        push!(heap,(chains[j][heads[j]].reference,j));i=length(heap)
        while i>1
            p=i÷2;heap[p]<=heap[i]&&break;heap[p],heap[i]=heap[i],heap[p];i=p
        end
    end
    function pophead()
        item=first(heap);last=pop!(heap)
        if !isempty(heap)
            heap[1]=last;i=1
            while 2i<=length(heap)
                c=2i;c<length(heap)&&heap[c+1]<heap[c]&&(c+=1)
                heap[i]<=heap[c]&&break;heap[i],heap[c]=heap[c],heap[i];i=c
            end
        end
        item
    end
    for j in eachindex(jobs);pushhead(j);end
    earlier(a,b)=a.reference<b.reference || (a.reference==b.reference &&
        (a.event!=b.event ? solution["y"][a.event][b.event]==1 :
        (a.route,a.instance,a.source,a.job)<(b.route,b.instance,b.source,b.job)))
    entries=Any[]
    while !isempty(heap)
        reference=first(heap)[1];tied=Int[]
        while !isempty(heap)&&first(heap)[1]==reference;push!(tied,pophead()[2]);end
        sort!(tied);best=first(tied)
        for j in tied[2:end];earlier(chains[j][heads[j]],chains[best][heads[best]])&&(best=j);end
        e=chains[best][heads[best]];e.source==heads[best]||throw(ArgumentError("工程対応が不正です"))
        push!(entries,Dict("rank"=>length(entries)+1,"transfer_id"=>transfer_id(e.job,e.source),
            "job_id"=>e.job,"source_operation"=>e.source))
        heads[best]+=1;for j in tied;pushhead(j);end
    end
    entries
end
function validate_entries(entries, mapping)
    lookup = Dict(m["job_id"]=>m for m in mapping)
    seen = Set{String}()
    next = Dict(id=>1 for id in keys(lookup))
    for (rank,e) in enumerate(entries)
        id, source = e["job_id"], e["source_operation"]
        haskey(lookup,id) || throw(ArgumentError("未知のジョブ"))
        source == next[id] && source < lookup[id]["operation_count"] || throw(ArgumentError("工程順が不正です"))
        e["rank"] == rank && e["transfer_id"] == transfer_id(id,source) || throw(ArgumentError("順位形式が不正です"))
        e["transfer_id"] in seen && throw(ArgumentError("搬送ID重複"))
        Set(keys(e)) == Set(["rank","transfer_id","job_id","source_operation"]) || throw(ArgumentError("制御データに余分な項目があります"))
        push!(seen,e["transfer_id"]); next[id] += 1
    end
    length(entries) == sum(m["operation_count"]-1 for m in mapping; init=0) || throw(ArgumentError("搬送順位の件数不一致"))
    true
end

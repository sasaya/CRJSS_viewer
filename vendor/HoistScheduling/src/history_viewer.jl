# HTMLは全フレームを内包するため、保存したanimation.htmlだけでオフライン再生できます。
# Plutoでも同じ描画コードを使い、更新のたびに再生位置をリセットしません。
function history_html(directory::AbstractString;pluto=false,feed_url=nothing)
    path=joinpath(directory,"history.json")
    document=isfile(path) ? JSON.parsefile(path) : Dict("status"=>"PREPARING","entries"=>[])
    frames=Any[]
    for entry in (pluto && !isnothing(feed_url) ? [] : document["entries"])
        prefix=joinpath(directory,entry["prefix"])
        push!(frames,merge(Dict(entry),Dict("trajectory"=>read(prefix*"_trajectory.svg",String),
                                         "gantt"=>read(prefix*".svg",String))))
    end
    data=Dict("status"=>document["status"],"error"=>get(document,"error",nothing),"final"=>get(document,"final",nothing),
              "directory"=>abspath(directory),"frames"=>frames)
    # JSON中のHTML終了タグを無害化します。図はこのプロジェクトのSVG生成関数製です。
    payload=replace(JSON.json(data),"<"=>"\\u003c","\u2028"=>"\\u2028","\u2029"=>"\\u2029")
    script=read(joinpath(@__DIR__,"history_player.js"),String)
    if pluto
        connection=isnothing(feed_url) ? "" : "root._hoist.startPoll($(JSON.json(feed_url)));"
        return """<script>
        $script
        const root = this instanceof HTMLElement ? this : document.createElement('div');
        mountHoistHistory(root,$payload);
        $connection
        invalidation.then(()=>setTimeout(()=>{if(!root.isConnected && root._hoist) root._hoist.destroy();},100));
        return root;
        </script>"""
    end
    return """<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>最良解の更新履歴</title></head>
    <body><div id="hoist-history"></div><script>$script
    mountHoistHistory(document.getElementById('hoist-history'),$payload);
    </script></body></html>"""
end

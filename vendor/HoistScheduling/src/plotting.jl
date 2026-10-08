# SVGは文字列だけで作れるため、Makie・ブラウザー・Pythonの追加インストールは不要です。
# 作図には保存済みの計算結果を使います。終端処理をLの値で描き足すことはしません。

escape_xml(x)=replace(string(x),"&"=>"&amp;","<"=>"&lt;",">"=>"&gt;","\""=>"&quot;")
fmt(x)=@sprintf("%.2f",x)
route_color(r)="hsl($(mod(r*137.5,360)),62%,39%)"

"""周期をまたぐ区間を、一周期[0,T]の図に収まる断片へ分けます。"""
function periodic_segments(start,finish,T)
    pieces=Tuple{Float64,Float64}[]
    for shift in floor(Int,-finish/T)-1:ceil(Int,(T-start)/T)+1
        left=max(0,start+shift*T); right=min(T,finish+shift*T)
        right>left && push!(pieces,(left,right))
    end
    return pieces
end

"""図とCSVの共通データ。終端のdwellは求解した排出時刻から計算します。"""
function schedule_rows(p::HoistProblem,result)
    verify_result(p,result)["valid"] || error("検証を通過した解だけを描画できます")
    sol=result["solution"]; T=sol["T"]
    rows=Any[]
    for a in eachindex(p.events)
        b=p.previous[a]; start=sol["starts"][a]
        cycles=b==0 ? 0 : sol["k"][a]-1+sol["y"][a][b]
        arrival=b==0 ? start : sol["starts"][b]+p.duration[b]
        process_end=start+cycles*T
        dwell=b==0 ? 0 : process_end-arrival
        # 終端の図を表示するホイストは、品物を最後に搬入したホイストです。
        # これは図の配置先であり、自動排出にホイストを割り当てる意味ではありません。
        plot_hoist=p.terminal[a] ? sol["hoists"][b]+1 : sol["hoists"][a]+1
        push!(rows,(route=p.events[a][1],stage=p.events[a][2],terminal=p.terminal[a],
            source=p.source[a],destination=p.destination[a],hoist=sol["hoists"][a],
            plot_hoist=plot_hoist,start=start,finish=start+p.duration[a],
            processing_start=arrival,processing_end=process_end,dwell=dwell,cycles=cycles))
    end
    return rows
end

function svg_line(x1,y1,x2,y2,color;class="",style="",title="")
    return "<line class=\"$class\" x1=\"$(fmt(x1))\" y1=\"$(fmt(y1))\" x2=\"$(fmt(x2))\" y2=\"$(fmt(y2))\" stroke=\"$color\" $style><title>$(escape_xml(title))</title></line>"
end

function svg_header(width,height,title)
    return String["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\">",
        "<style>text{font-family:Arial,'Yu Gothic',sans-serif;fill:#263238}.job-label{font-size:10px}.axis{font-size:11px}</style>",
        "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>",
        "<text x=\"24\" y=\"28\" font-size=\"19\">$(escape_xml(title))</text>"]
end

"""従来のJOB別ガント図。終端処理は搬送とは別の行で表示します。"""
function gantt_svg(rows,T)
    width=1560; height=95+length(rows)*24
    left=240; scale=1270/T
    svg=svg_header(width,height,"JOB / processing Gantt — T=$T")
    push!(svg,"<text x=\"24\" y=\"50\" font-size=\"12\">Terminal rows show computed processing time, not a hoist move.</text>")
    for (line,row) in enumerate(sort(rows;by=r->r.start))
        y=65+(line-1)*24
        label=row.terminal ? "r$(row.route) p$(row.stage): Station $(row.source) (auto)" :
                             "r$(row.route) i$(row.stage): $(row.source)→$(row.destination) H$(row.hoist+1)"
        push!(svg,"<text x=\"12\" y=\"$(y+13)\" font-size=\"12\">$(escape_xml(label))</text>")
        pieces=row.terminal ? periodic_segments(row.processing_start,row.processing_end,T) : [(row.start,row.finish)]
        for (a,b) in pieces
            push!(svg,"<rect x=\"$(fmt(left+a*scale))\" y=\"$y\" width=\"$(fmt(max(1,(b-a)*scale)))\" height=\"15\" fill=\"$(route_color(row.route))\"><title>$(row.terminal ? row.dwell : b-a)</title></rect>")
        end
    end
    push!(svg,"</svg>")
    return join(svg,"\n")
end

"""元のhoist_cyclic.jlと同じ、時刻×槽番号の軌跡図です。"""
function trajectory_svg(p,rows,T,H)
    width=1680; left=80; right=1640
    legend_columns=14;top=128+23*(cld(p.raw["R"],legend_columns)-1)
    minimum_station=1; maximum_station=maximum(p.destination ∪ p.source)
    span=max(1,maximum_station-minimum_station)
    panel_height=max(260,span*18+56); stride=panel_height+75
    handling_top=top+(H+1)*stride
    height=handling_top+100+H*28
    sx(t)=left+(right-left)*t/T
    svg=svg_header(width,height,"Time / station — T=$T, $H hoist(s), $(length(p.moves)) moves")
    push!(svg,"<text x=\"24\" y=\"50\" font-size=\"12\">Solid: loaded | Dashed: empty | Colored horizontal: processing | Open circle: automatic discharge</text>")
    push!(svg,"<text x=\"24\" y=\"69\" font-size=\"12\">Station1 terminal bars use optimized completion times (including wraparound at T).</text>")
    for r in 1:p.raw["R"]
        x=26+mod(r-1,legend_columns)*110;y=95+fld(r-1,legend_columns)*23
        push!(svg,svg_line(x,y,x+25,y,route_color(r);style="stroke-width=\"4\""))
        push!(svg,"<text x=\"$(x+31)\" y=\"$(y+4)\" font-size=\"12\">route $r</text>")
    end
    tick_step=max(10,ceil(Int,T/120)*10)
    ticks=sort!(unique(vcat(collect(0:tick_step:T),[T])))
    moves=sort([r for r in rows if !r.terminal];by=r->r.start)

    for panel in 1:H+1
        panel_top=top+(panel-1)*stride
        sy(w)=panel_top+panel_height-28-(w-minimum_station)*(panel_height-56)/span
        title=panel<=H ? "Hoist $panel" : "All hoists / all processing"
        push!(svg,"<text x=\"24\" y=\"$(panel_top-9)\" font-size=\"16\">$title</text>")
        for w in minimum_station:maximum_station
            push!(svg,svg_line(left,sy(w),right,sy(w),"#e9edf0"))
            push!(svg,"<text class=\"axis\" x=\"$(left-30)\" y=\"$(sy(w)+4)\">$w</text>")
        end
        for tick in ticks
            push!(svg,svg_line(sx(tick),panel_top+15,sx(tick),panel_top+panel_height-18,"#edf0f3"))
            push!(svg,"<text class=\"axis\" text-anchor=\"middle\" x=\"$(sx(tick))\" y=\"$(panel_top+panel_height+2)\">$tick</text>")
        end
        push!(svg,"<text class=\"axis\" x=\"$(right-30)\" y=\"$(panel_top+panel_height+23)\">Time</text>")
        push!(svg,"<text class=\"axis\" x=\"8\" y=\"$(panel_top+16)\">Station</text>")

        for row in rows
            row.stage==1 && continue
            panel<=H && row.plot_hoist!=panel && continue
            offset=(row.route-(p.raw["R"]+1)/2)*0.035
            y=sy(row.source+offset)
            class=row.terminal ? "terminal" : "dwell"
            for (a,b) in periodic_segments(row.processing_start,row.processing_end,T)
                title="r$(row.route) p$(row.stage): $(row.dwell), $(row.processing_start)–$(row.processing_end)"
                push!(svg,svg_line(sx(a),y,sx(b),y,route_color(row.route);class,
                                  style="stroke-width=\"3\" opacity=\"0.85\"",title))
            end
            if row.terminal
                # 終端処理終了（自動排出）を丸で示します。搬送線は描きません。
                t=mod(row.processing_end,T)
                push!(svg,"<circle class=\"terminal\" cx=\"$(sx(t))\" cy=\"$y\" r=\"4\" fill=\"white\" stroke=\"$(route_color(row.route))\"><title>auto discharge r$(row.route)</title></circle>")
                push!(svg,"<text class=\"job-label terminal\" x=\"$(sx(t)+4)\" y=\"$(y-9)\">p$(row.stage)=$(row.dwell)</text>")
            end
        end

        selected=[r for r in moves if panel>H || r.plot_hoist==panel]
        for h in 1:H
            on_hoist=[r for r in selected if r.plot_hoist==h]
            for (i,row) in enumerate(on_hoist)
                destination=i<length(on_hoist) ? on_hoist[i+1].source : 1
                deadline=i<length(on_hoist) ? on_hoist[i+1].start : T
                travel=p.travel[row.destination,destination]
                arrive=row.finish+travel
                arrive<=deadline+1e-5 || error("空移動を描く時間が足りません")
                if travel>0
                    push!(svg,svg_line(sx(row.finish),sy(row.destination),sx(arrive),sy(destination),"#555";
                        class="empty",style="stroke-dasharray=\"6 4\" stroke-width=\"1.4\""))
                end
                if arrive<deadline
                    push!(svg,svg_line(sx(arrive),sy(destination),sx(deadline),sy(destination),"#999";
                        class="idle",style="stroke-dasharray=\"2 4\""))
                end
            end
        end
        for row in selected
            title="r$(row.route) i$(row.stage) H$(row.hoist+1): $(row.start)–$(row.finish)"
            push!(svg,svg_line(sx(row.start),sy(row.source),sx(row.finish),sy(row.destination),"#181818";
                              class="loaded",style="stroke-width=\"2\"",title))
            push!(svg,"<text class=\"job-label\" x=\"$(sx(row.start)+3)\" y=\"$(sy(row.source)-5)\">r$(row.route),i$(row.stage) $(row.start)</text>")
        end
    end
    push!(svg,"<text x=\"24\" y=\"$handling_top\" font-size=\"16\">Handling (real moves only)</text>")
    for h in 1:H
        y=handling_top+18+(h-1)*28
        push!(svg,"<text class=\"axis\" x=\"20\" y=\"$(y+15)\">H$h</text>")
        push!(svg,"<rect x=\"$left\" y=\"$y\" width=\"$(right-left)\" height=\"19\" fill=\"#f1f3f4\"/>")
        for row in moves
            row.plot_hoist!=h && continue
            push!(svg,"<rect x=\"$(sx(row.start))\" y=\"$y\" width=\"$(sx(row.finish)-sx(row.start))\" height=\"19\" fill=\"$(route_color(row.route))\"><title>r$(row.route),i$(row.stage)</title></rect>")
        end
    end
    push!(svg,"</svg>")
    return join(svg,"\n")
end

function write_viewer(path,svg)
    page="""<!doctype html><html lang="ja"><meta charset="utf-8"><title>ホイスト軌跡図</title>
    <style>body{font-family:sans-serif;margin:20px}label{margin-right:16px}.chart{overflow:auto}header{position:sticky;top:0;background:white;z-index:1;padding:10px}</style>
    <header><b>ホイスト軌跡図</b>　"""
    for (class,label) in [("job-label","時刻ラベル"),("dwell","槽内処理"),("terminal","終端処理"),("empty","空移動"),("idle","待機")]
        page*="<label><input type=\"checkbox\" checked data-class=\"$class\">$label</label>"
    end
    page*="</header><div class=\"chart\">$svg</div>"
    page*="""<script>
    document.querySelectorAll('input[data-class]').forEach(box=>box.addEventListener('change',()=>{
      document.querySelectorAll('svg [class]').forEach(el=>{
        el.style.display=[...document.querySelectorAll('input[data-class]')].some(b=>!b.checked&&el.classList.contains(b.dataset.class))?'none':'';
      });
    }));</script></html>"""
    write(path,page)
end

"""旧形式のガント図と軌跡図を、両方保存します。既存ファイルは別名なら残ります。"""
function export_plots(p::HoistProblem,result,prefix::AbstractString)
    rows=schedule_rows(p,result); T=result["solution"]["T"]
    mkpath(dirname(abspath(prefix)))
    write(prefix*".svg",gantt_svg(rows,T))
    svg=trajectory_svg(p,rows,T,result["hoist_count"])
    write(prefix*"_trajectory.svg",svg)
    write_viewer(prefix*"_trajectory.html",svg)
    open(prefix*".csv","w") do io
        println(io,"route,stage,type,station,to,hoist,phase,move_finish,processing_start,processing_end,dwell,cycles")
        for r in rows
            fields=(r.route,r.stage,r.terminal ? "automatic_discharge" : "move",r.source,r.destination,
                    isnothing(r.hoist) ? "" : r.hoist+1,r.start,r.finish,r.processing_start,r.processing_end,r.dwell,r.cycles)
            println(io,join(fields,","))
        end
    end
    return prefix*"_trajectory.html"
end

-- 一括設定の正規データはREAPERプロジェクト。画面を閉じても拡張が適用を続ける。
if not reaper.APIExists('PitchCanvasPrecision_CheckRelease') then
  reaper.ShowMessageBox('Update Adaptive Precision and restart REAPER.', 'Pitch Canvas Extension — Adaptive Precision', 0)
  return
end

-- PitchCanvasのColorPalette / GuiTokensと同じ無彩色、選択色、4pt基底の余白。
local colour = {
  background=0x202020, panel=0x282828, line=0x383838, outline=0x424242,
  text=0xf0f0f0, secondary=0xc1c1c1, muted=0xadadad,
  selected=0x303744, selectedOutline=0x8196b9, success=0x9cbbb0,
  hover=0x383838, pressed=0x252525,
}
local scriptDirectory=debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])')
local comparison=dofile(scriptDirectory..'PrecisionCheck.lua').new()
local pressedAction=nil
local layout = {padding=24, row=48, listTop=152, footer=40, minimumWidth=360, minimumHeight=440}
local keyCode = {down=1685026670, up=30064, pageDown=1885824110, pageUp=1885828464, home=1752132965, finish=6647396}
local commandModifiers = 4 | 16 | 32
local operatingSystem = reaper.GetOS()
local isMac = operatingSystem:match('OSX') ~= nil or operatingSystem:match('macOS') ~= nil
local fontFace = isMac and 'Helvetica Neue' or 'Segoe UI'
local scale, width, height = 1, 600, 568
local rows, enabled, mixed, project = {}, false, false, nil
local lastRefresh, scroll = 0, 0
local previousDown, pressedProject, dragOffset = false, nil, nil
local keyboardFocus, lastToggle = false, -1

gfx.ext_retina = 1
gfx.init('Pitch Canvas Extension — Adaptive Precision', width, height)
-- macOSだけinitのサイズが論理pt。Windowsは高DPI時の初期サイズも拡大する。
if not isMac and gfx.ext_retina>1 then gfx.init('',width*gfx.ext_retina,height*gfx.ext_retina) end
reaper.atexit(function() comparison:close();gfx.quit() end)

local function setColour(value)
  gfx.set(((value >> 16) & 255)/255, ((value >> 8) & 255)/255, (value & 255)/255, 1)
end
local function rect(x,y,w,h,c)
  setColour(c); gfx.rect(x*scale,y*scale,w*scale,h*scale,true)
end
local function rule(x,y,w)
  rect(x,y,w,1/scale,colour.line)
end
local function rounded(x,y,w,h,r,c)
  setColour(c)
  gfx.rect((x+r)*scale,y*scale,(w-2*r)*scale,h*scale,true)
  gfx.rect(x*scale,(y+r)*scale,w*scale,(h-2*r)*scale,true)
  for _,cx in ipairs({x+r,x+w-r}) do
    for _,cy in ipairs({y+r,y+h-r}) do gfx.circle(cx*scale,cy*scale,r*scale,true,true) end
  end
end
local function font(size,bold)
  gfx.setfont(bold and 2 or 1,fontFace,math.floor(size*scale+.5),bold and string.byte('b') or 0)
end
local function fitted(value,w)
  if w<=0 then return '' end
  if gfx.measurestr(value)<=w*scale then return value end
  local ending='…'
  if gfx.measurestr(ending)>w*scale then return '' end
  -- byte単位で切らず、日本語のトラック名も保持する。
  local offsets={}
  for pos in value:gmatch('()[%z\1-\127\194-\244][\128-\191]*') do offsets[#offsets+1]=pos end
  local lo,hi=0,#offsets
  while lo<hi do
    local mid=math.ceil((lo+hi)/2)
    local candidate=value:sub(1,(offsets[mid+1] or (#value+1))-1)..ending
    if gfx.measurestr(candidate)<=w*scale then lo=mid else hi=mid-1 end
  end
  return value:sub(1,(offsets[lo+1] or (#value+1))-1)..ending
end
local function label(x,y,w,h,value,size,c,align,bold)
  font(size,bold); setColour(c)
  gfx.x=x*scale; gfx.y=y*scale
  gfx.drawstr(fitted(value,w),4|(align or 0),(x+w)*scale,(y+h)*scale)
end
local function hit(x,y,w,h,mx,my)
  return mx>=x and mx<x+w and my>=y and my<y+h
end
local function refresh()
  local current=reaper.EnumProjects(-1,'')
  if current~=project then scroll=0; pressedProject=nil; pressedAction=nil; dragOffset=nil end
  project=current
  enabled=reaper.PitchCanvasPrecision_GetProjectEnabled(project)==1
  rows={}
  for i=-1,reaper.CountTracks(project)-1 do
    local track=i==-1 and reaper.GetMasterTrack(project) or reaper.GetTrack(project,i)
    local _,trackName=reaper.GetTrackName(track)
    for fx=0,reaper.TrackFX_GetCount(track)-1 do
      if reaper.PitchCanvasPrecision_IsTrackFXTarget(track,fx)==1 then
        local _,name=reaper.TrackFX_GetFXName(track,fx,'')
        -- 表示だけを整え、ユーザーのFX名や音源識別は書き換えない。
        name=name:gsub('^VST3i?:%s*','')
        local mode=reaper.PitchCanvasPrecision_GetTrackFXMode(track,fx)
        rows[#rows+1]={title=name,trackName=trackName,track=track,fx=fx,project=project,guid=reaper.TrackFX_GetFXGUID(track,fx),
          excluded=reaper.PitchCanvasPrecision_GetTrackFXCompatibility(track,fx)==0,
          on=mode~=0 and mode~=-2}
      end
    end
  end
  local on,off=0,0
  local selected
  for _,row in ipairs(rows) do
    if not row.excluded then if row.on then on=on+1 else off=off+1 end end
    if comparison.row and comparison.row.guid==row.guid and comparison.row.project==project then selected=row end
  end
  if on+off>0 then enabled=on>0 and off==0 end
  mixed=on>0 and off>0
  if not comparison.active then
    if not selected then comparison:select(rows[1]) else comparison.row=selected end
  end
  comparison:poll()
end
local function toggle(expectedProject)
  -- マウスを押している間のタブ切替で、別プロジェクトへ適用しない。
  if comparison.active then return end
  if expectedProject==reaper.EnumProjects(-1,'') then
    local current=enabled and not mixed
    reaper.PitchCanvasPrecision_SetProjectEnabled(expectedProject,current and 0 or 1)
  end
  refresh()
end
local function frame()
  comparison:tick()
  local key=gfx.getchar()
  if key<0 or key==27 then return end
  scale=math.max(1,gfx.ext_retina or 1)
  width,height=gfx.w/scale,gfx.h/scale
  local now=reaper.time_precise()
  if now-lastRefresh>.25 then refresh();lastRefresh=now end
  local mx,my=gfx.mouse_x/scale,gfx.mouse_y/scale
  local down=(gfx.mouse_cap&1)==1
  local pressed=down and not previousDown
  local released=not down and previousDown
  local pad=layout.padding
  rect(0,0,width,height,colour.background)

  if width<layout.minimumWidth or height<layout.minimumHeight then
    pressedProject=nil;dragOffset=nil
    label(16,16,width-32,28,'Adaptive Precision',20,colour.muted,0,true)
    label(16,52,width-32,24,'Enlarge the window to view instruments.',13,colour.secondary)
  else
    local button={x=width-pad-76,y=64,w=76,h=32}
    local inside=hit(button.x,button.y,button.w,button.h,mx,my)
    local bottom=height-layout.footer
    local detailHeight=width<560 and 196 or 164
    local detailTop=bottom-detailHeight
    local visible=math.max(1,math.floor((detailTop-layout.listTop)/layout.row))
    local maximum=math.max(0,#rows-visible)
    local listHeight=visible*layout.row
    local barX,barY,barH=width-12,layout.listTop,listHeight
    local thumbH=maximum>0 and math.max(24,barH*visible/#rows) or barH
    if gfx.mouse_wheel~=0 then
      scroll=scroll-gfx.mouse_wheel/120
      gfx.mouse_wheel=0
    end
    if key==9 then keyboardFocus=true end
    if (gfx.mouse_cap&commandModifiers)==0 then
      if key==99 or key==67 then comparison:start()
      elseif key==97 or key==65 then comparison:listen(0)
      elseif key==98 or key==66 then comparison:listen(1)
      elseif key==121 or key==89 then comparison:choose(true)
      elseif key==110 or key==78 then comparison:choose(false) end
    end
    if (key==32 or key==13) and (gfx.mouse_cap&commandModifiers)==0 then
      keyboardFocus=true
      if now-lastToggle>.3 then toggle(project);lastToggle=now end
    elseif key==keyCode.down then scroll=scroll+1 -- Down
    elseif key==keyCode.up then scroll=scroll-1 -- Up
    elseif key==keyCode.pageDown then scroll=scroll+visible -- Page down
    elseif key==keyCode.pageUp then scroll=scroll-visible -- Page up
    elseif key==keyCode.home then scroll=0 -- Home
    elseif key==keyCode.finish then scroll=maximum end -- End
    scroll=math.max(0,math.min(maximum,math.floor(scroll+.5)))
    local thumbY=barY+(maximum>0 and scroll/maximum*(barH-thumbH) or 0)
    if pressed then
      keyboardFocus=false
      pressedProject=inside and project or nil
      if maximum>0 and hit(barX-4,barY,12,barH,mx,my) then
        if hit(barX-4,thumbY,12,thumbH,mx,my) then dragOffset=my-thumbY
        else scroll=math.max(0,math.min(maximum,scroll+(my<thumbY and -visible or visible))) end
      end
    end
    if down and dragOffset and maximum>0 then
      scroll=math.max(0,math.min(maximum,math.floor((my-barY-dragOffset)/(barH-thumbH)*maximum+.5)))
    end
    if released then
      if inside and pressedProject then toggle(pressedProject) end
      pressedProject=nil;dragOffset=nil
    end

    label(pad,8,width-2*pad,22,'Pitch Canvas Extension',14,colour.muted,1)
    label(pad,30,width-2*pad,26,'Adaptive Precision',20,colour.text,1,true)
    label(pad,64,width-2*pad-160,32,'Project',16,colour.text)
    label(pad,98,width-2*pad,20,'VST3 instruments on Pitch Canvas tracks',12,colour.muted)
    label(button.x-76,button.y,64,button.h,'Adaptive',12,colour.secondary,2)
    rounded(button.x,button.y,button.w,button.h,16,
      inside and down and colour.pressed or inside and colour.hover or enabled and colour.selected or colour.panel)
    setColour((enabled or keyboardFocus) and colour.selectedOutline or colour.outline)
    gfx.roundrect(button.x*scale,button.y*scale,button.w*scale,button.h*scale,16*scale,true)
    setColour(enabled and colour.success or colour.muted)
    gfx.circle((button.x+20)*scale,(button.y+16)*scale,3*scale,true,true)
    label(button.x+28,button.y,44,button.h,mixed and 'Mixed' or enabled and 'On' or 'Off',mixed and 11 or 13,colour.text)
    label(pad,128,width-2*pad-96,20,'INSTRUMENT / TRACK',10,colour.muted)
    label(width-pad-84,128,84,20,'STATE',10,colour.muted,2)
    rule(pad,layout.listTop-1,width-2*pad)

    if #rows==0 then
      label(pad,layout.listTop+12,width-2*pad,24,'No instruments on Pitch Canvas tracks',14,colour.secondary)
      if visible>=2 then
        label(pad,layout.listTop+40,width-2*pad,20,'Add Pitch Canvas and a VST3 synth to the same track.',12,colour.muted)
      end
    end
    for i=scroll+1,math.min(#rows,scroll+visible) do
      local row=rows[i]
      local y=layout.listTop+(i-scroll-1)*layout.row
      local textWidth=width-2*pad-104
      label(pad,y+5,textWidth,22,row.title,14,colour.text)
      if comparison.row and comparison.row.guid==row.guid then
        rect(pad-8,y+2,width-2*pad+16,layout.row-4,colour.panel)
        label(pad,y+5,textWidth,22,row.title,14,colour.text)
      end
      if pressed and not comparison.active and hit(pad,y,width-2*pad,layout.row,mx,my) then comparison:select(row) end
      local detail=row.trackName..(row.excluded and ' · Precision not supported' or '')
      label(pad,y+26,width-2*pad,16,detail,11,colour.muted)
      label(width-pad-84,y+5,84,22,row.excluded and 'Excluded' or row.on and 'On' or 'Off',12,
        row.on and not row.excluded and colour.success or colour.muted,2)
      if i<math.min(#rows,scroll+visible) then rule(pad,y+layout.row-1,width-2*pad) end
    end
    if maximum>0 then
      thumbY=barY+scroll/maximum*(barH-thumbH)
      rounded(barX,barY,3,barH,1.5,colour.panel)
      rounded(barX,thumbY,3,thumbH,1.5,dragOffset and colour.secondary or colour.muted)
    end
    rule(pad,detailTop,width-2*pad)
    label(pad,detailTop+8,width-2*pad,20,'QUICK COMPARISON',10,colour.muted)
    local state=comparison.active
    local result=comparison.result
    local headline=comparison.row and comparison.row.title or 'Select an instrument above'
    if state then headline=string.format('%s · Pass %d/3 · %.1f / %.1f s',state.pass==1 and 'Adaptive' or 'Off',math.min(3,state.pass+1),math.min(state.duration,now-state.passStarted),state.duration)
    elseif result then headline=(result[11] or 'Review')..(comparison.matching and ' · Saved result' or ' · Previous conditions') end
    label(pad,detailTop+32,width-2*pad,24,headline,14,colour.text)
    local metrics='Uses up to 2 seconds from the time selection or cursor.'
    if result and tonumber(result[1]) and tonumber(result[2]) then
      metrics=string.format('Process %.2f → %.2f%%',((tonumber(result[1]) or 0)+(tonumber(result[3]) or 0))/2,tonumber(result[2]))
      if result[7]=='1' then metrics=string.format('Pitch %.1f → %.1f ct · ',((tonumber(result[4]) or 0)+(tonumber(result[6]) or 0))/2,tonumber(result[5]) or 0)..metrics end
    end
    label(pad,detailTop+60,width-2*pad,20,metrics,12,colour.secondary)
    local note=comparison.notice~='' and comparison.notice or result and result[12] or 'Off → Adaptive → Off. No extra tracks or project files.'
    if comparison.record and comparison.record.decision~='Undecided' and comparison.notice=='' then note='Saved decision: '..comparison.record.decision end
    label(pad,detailTop+84,width-2*pad,20,note,11,colour.muted)
    local controls={
      {id='compare',text=state and 'Cancel' or 'Compare',w=88,allowed=comparison.row~=nil,run=function()comparison:start()end},
      {id='a',text='Listen A',w=78,allowed=comparison.audioKey~=nil and not state,run=function()comparison:listen(0)end},
      {id='b',text='Listen B',w=78,allowed=comparison.audioKey~=nil and not state,run=function()comparison:listen(1)end},
      {id='on',text='Use Adaptive',w=112,allowed=comparison.record~=nil and not state and not (comparison.row and comparison.row.excluded),run=function()comparison:choose(true)end},
      {id='off',text='Keep Off',w=88,allowed=comparison.record~=nil and not state,run=function()comparison:choose(false)end},
    }
    local x,y=pad,detailTop+116
    for _,control in ipairs(controls) do
      if x+control.w>width-pad then x=pad;y=y+36 end
      local over=hit(x,y,control.w,28,mx,my)
      rounded(x,y,control.w,28,5,over and control.allowed and colour.hover or colour.panel)
      label(x,y,control.w,28,control.text,12,control.allowed and colour.text or colour.outline,1)
      if pressed and over and control.allowed then pressedAction={id=control.id,project=project,guid=comparison.row and comparison.row.guid} end
      if released and over and control.allowed and pressedAction and pressedAction.id==control.id
        and pressedAction.project==project and comparison.row and pressedAction.guid==comparison.row.guid then control.run() end
      x=x+control.w+8
    end
    if released then pressedAction=nil end
    rule(pad,bottom,width-2*pad)
    label(pad,bottom+8,width-2*pad-112,24,'C Compare · A/B Listen · Y/N Apply',11,colour.muted)
    local count=maximum>0 and string.format('%d–%d / %d',scroll+1,math.min(#rows,scroll+visible),#rows)
      or string.format('%d instrument%s',#rows,#rows==1 and '' or 's')
    label(width-pad-112,bottom+8,112,24,count,11,colour.muted,2)
  end
  previousDown=down
  gfx.update();reaper.defer(frame)
end
frame()

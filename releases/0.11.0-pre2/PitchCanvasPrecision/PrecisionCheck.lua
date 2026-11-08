-- 比較は既存の音源で完結させる。共通保存には指標とhashだけを残し、音色stateや音声を保存しない。
local M={}
local section='PitchCanvas.PrecisionChecks.v1'
local maximumSeconds=2
local minimumSeconds=.25
local timeoutSeconds=9
local passGraceSeconds=1
local function hash(value)
  local h=0xcbf29ce484222325
  for i=1,#value do h=(h~value:byte(i))*0x100000001b3 end
  return string.format('%016x',h)
end
local function pack(fields)
  local out={}
  for i,value in ipairs(fields) do out[i]=tostring(value):gsub('[%%|\r\n]',function(c)return string.format('%%%02X',c:byte())end) end
  return table.concat(out,'|')
end
local function unpackFields(value)
  local out={}
  for field in (value..'|'):gmatch('(.-)|') do out[#out+1]=field:gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end) end
  return out
end
local function decode64(value)
  local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local lookup={};for i=1,#alphabet do lookup[alphabet:byte(i)]=i-1 end
  local out,bits,count={},0,0
  for i=1,#value do
    local v=lookup[value:byte(i)]
    if v then
      bits=(bits<<6)|v;count=count+6
      if count>=8 then count=count-8;out[#out+1]=string.char((bits>>count)&255);bits=bits&((1<<count)-1) end
    end
  end
  return table.concat(out)
end
local function valid(row)
  if not row or not reaper.ValidatePtr2(row.project,row.track,'MediaTrack*') then return false end
  for fx=0,reaper.TrackFX_GetCount(row.track)-1 do
    if reaper.TrackFX_GetFXGUID(row.track,fx)==row.guid then row.fx=fx;return true end
  end
  return false
end
local function mapping(row)
  local range,source,found=0,{},0
  for fx=0,reaper.TrackFX_GetCount(row.track)-1 do
    local _,id=reaper.TrackFX_GetNamedConfigParm(row.track,fx,'fx_ident')
    if id and (id:find('PitchCanvas.vst3',1,true) or id=='com.pontakuaudio.pitchcanvas' or id=='Pontaku Audio: PitchCanvas') then
      found=found+1
      local _,kind=reaper.TrackFX_GetNamedConfigParm(row.track,fx,'fx_type')
      local _,state=reaper.TrackFX_GetNamedConfigParm(row.track,fx,kind:find('CLAP',1,true) and 'clap_chunk' or 'vst_chunk')
      state=state or '';source[#source+1]=id..':'..hash(state)
      local raw=decode64(state)
      range=tonumber(raw:match('bendRangeSemitones="([%d%.]+)"')) or 0
    end
  end
  if found~=1 then range=0 end
  return range,hash(table.concat(source,'|'))
end
local function context(row,from,duration)
  local ok,info=reaper.PitchCanvasPrecision_CheckInfo(row.track,row.fx,'',4096)
  if ok~=1 then return nil end
  local parts=unpackFields(info)
  local rate,block=tonumber(parts[2]),tonumber(parts[3])
  if not rate or not block then return nil end
  local _,state=reaper.TrackFX_GetNamedConfigParm(row.track,row.fx,'vst_chunk')
  local range,curve=mapping(row)
  local bend=tonumber(parts[4]) or -1
  local base=hash(parts[1]..'|'..reaper.GetOS())
  local scope=pack({parts[1],reaper.GetOS(),rate,block,hash(state or ''),curve,
    reaper.Master_GetTempo(),from,duration,bend,range})
  return {key=hash(scope),base=base,scope=scope,rate=rate,block=block,bend=bend,range=range}
end
local function selection(project)
  local from,to=reaper.GetSet_LoopTimeRange2(project,false,false,0,0,false)
  if to<=from then from=reaper.GetCursorPositionEx(project);to=from+maximumSeconds end
  return from,to-from
end
local function readRecord(key)
  local raw=reaper.GetExtState(section,key)
  if raw=='' then return nil end
  local f=unpackFields(raw)
  if #f~=7 or f[1]~='1' or #f[2]>4096 or #f[3]>4096 or not tonumber(f[5])
    or (f[4]~='Undecided' and f[4]~='Adaptive' and f[4]~='Off') or hash(f[2])~=key then return nil end
  local metrics=unpackFields(f[3])
  if #metrics~=12 then return nil end
  for i=1,10 do local number=tonumber(metrics[i]);if not number or math.abs(number)==math.huge then return nil end end
  return {key=key,scope=f[2],metrics=f[3],decision=f[4],time=f[5],title=f[6],base=f[7]}
end
local function store(record)
  reaper.SetExtState(section,record.key,pack({'1',record.scope,record.metrics,record.decision,record.time,record.title,record.base}),true)
  reaper.SetExtState(section,'latest_'..record.base,record.key,true)
end
function M.new()
  local self={row=nil,active=nil,result=nil,record=nil,notice='',matching=false,audioKey=nil}
  function self:select(row)
    if self.active then return end
    reaper.PitchCanvasPrecision_CheckListen(nil,0,-1)
    if valid(self.row) then reaper.PitchCanvasPrecision_CheckRelease(self.row.track,self.row.fx) end
    self.row=row;self.result=nil;self.record=nil;self.notice='';self.matching=false;self.audioKey=nil;self.observedStamp=nil
    if not valid(row) then return end
    local from,duration=selection(row.project)
    local c=context(row,from,duration)
    if not c then return end
    self.record=readRecord(c.key)
    if self.record and self.record.scope~=c.scope then self.record=nil end
    self.matching=self.record~=nil
    if not self.record then self.record=readRecord(reaper.GetExtState(section,'latest_'..c.base)) end
    if self.record and self.record.base~=c.base then self.record=nil end
    if self.record then self.result=unpackFields(self.record.metrics) end
  end
  function self:poll()
    if self.active or not self.record or not valid(self.row) or reaper.GetPlayStateEx(self.row.project)~=0 then return end
    local from,duration=selection(self.row.project)
    local stamp=table.concat({reaper.GetProjectStateChangeCount(self.row.project),from,duration},':')
    if stamp==self.observedStamp then return end
    self.observedStamp=stamp
    local c=context(self.row,from,duration)
    self.matching=c and self.record.scope==c.scope or false
  end
  local function restore(a)
    if reaper.ValidatePtr(a.project,'ReaProject*') then
      local playing=reaper.GetPlayStateEx(a.project)
      if playing&4==0 then
        reaper.OnStopButtonEx(a.project)
        reaper.SetEditCurPos2(a.project,a.cursor,false,false)
        reaper.GetSetRepeatEx(a.project,a.repeatState)
      end
    end
  end
  function self:cancel(message)
    local a=self.active
    if a then
      if valid(a.row) then reaper.PitchCanvasPrecision_CheckCancel(a.row.track,a.row.fx) end
      restore(a);self.active=nil
    end
    if message then self.notice=message end
  end
  local function arm(a)
    if not valid(a.row) then return false end
    local c=a.context
    if reaper.PitchCanvasPrecision_CheckArm(a.row.track,a.row.fx,a.pass,a.from,a.duration,c.bend,c.range)~=1 then return false end
    reaper.SetEditCurPos2(a.project,a.from,false,false)
    a.passStarted=reaper.time_precise();a.stage='playing'
    reaper.OnPlayButtonEx(a.project);return true
  end
  function self:start()
    if self.active then self:cancel('Comparison cancelled.');return end
    local row=self.row
    if not valid(row) then self.notice='Select an instrument.';return end
    if reaper.GetPlayStateEx(row.project)~=0 then self.notice='Stop playback before comparing.';return end
    local override=reaper.GetGlobalAutomationOverride()
    if override>1 then self.notice='Switch automation to Read before comparing.';return end
    for i=-1,reaper.CountTracks(row.project)-1 do
      local tr=i<0 and reaper.GetMasterTrack(row.project) or reaper.GetTrack(row.project,i)
      if override<0 and reaper.GetMediaTrackInfo_Value(tr,'I_AUTOMODE')>1 then self.notice='Switch automation to Read before comparing.';return end
    end
    local from,duration=selection(row.project)
    if duration<minimumSeconds or duration>maximumSeconds then self.notice='Select 0.25–2 seconds, or clear the time selection.';return end
    local c=context(row,from,duration)
    if not c or c.rate<=0 or c.block<=0 then self.notice='Audio engine is not ready.';return end
    local a={row=row,project=row.project,context=c,from=from,duration=duration,pass=0,
      cursor=reaper.GetCursorPositionEx(row.project),repeatState=reaper.GetSetRepeatEx(row.project,-1),began=reaper.time_precise()}
    self.active=a;self.result=nil;self.record=nil;self.notice='';self.audioKey=nil
    reaper.GetSetRepeatEx(row.project,0)
    if not arm(a) then self:cancel('Could not start comparison.');return end
  end
  function self:tick()
    local a=self.active
    if not a then return end
    if not valid(a.row) or a.project~=reaper.EnumProjects(-1,'') then self:cancel('Comparison cancelled: project or instrument changed.');return end
    if reaper.GetPlayStateEx(a.project)&4~=0 then self:cancel('Comparison cancelled: recording started.');return end
    if reaper.time_precise()-a.began>timeoutSeconds then self:cancel('Comparison timed out; no setting was applied.');return end
    if a.stage=='next' then
      if a.pass==3 then
        local ok,metrics=reaper.PitchCanvasPrecision_CheckResult(a.row.track,a.row.fx,'',4096)
        self:cancel()
        if ok~=1 then self.notice='Could not analyze capture.';return end
        self.result=unpackFields(metrics)
        local current=context(a.row,a.from,a.duration)
        local c=a.context
        if current and current.scope~=c.scope then
          self.result[11]='Review';self.result[12]='Settings changed during comparison; listen or compare again.'
          metrics=table.concat(self.result,'|')
        end
        self.record={key=c.key,base=c.base,scope=c.scope,metrics=metrics,decision='Undecided',time=tostring(os.time()),title=a.row.title}
        store(self.record);self.matching=current and current.scope==c.scope or false;self.audioKey=c.key;self.observedStamp=nil
        self.notice=string.format('Saved locally · %.1f s',reaper.time_precise()-a.began)
        return
      end
      if not arm(a) then self:cancel('Could not start the next pass.');return end
    end
    local status=reaper.PitchCanvasPrecision_CheckStatus(a.row.track,a.row.fx)
    if status==2 then
      reaper.OnStopButtonEx(a.project);a.pass=a.pass+1;a.stage='next'
    elseif status<0 or status==0 then self:cancel('Capture interrupted; no setting was applied.')
    elseif reaper.time_precise()-a.passStarted>a.duration+passGraceSeconds then self:cancel('No complete audio capture; check the selected interval.')
    elseif reaper.GetPlayStateEx(a.project)==0 then self:cancel('Comparison stopped.') end
  end
  function self:listen(pass)
    if self.active or not valid(self.row) then return end
    if not self.record or self.audioKey~=self.record.key then self.notice='Run Compare to listen; saved records contain no audio.';return end
    if reaper.GetPlayStateEx(self.row.project)~=0 then self.notice='Stop playback before listening.';return end
    if reaper.PitchCanvasPrecision_CheckListen(self.row.track,self.row.fx,pass)~=1 then self.notice='Audio is available after a new comparison.' end
  end
  function self:choose(enabled)
    if self.active or not self.record or not valid(self.row) then return end
    local from,duration=selection(self.row.project)
    local c=context(self.row,from,duration)
    self.matching=c and self.record.scope==c.scope or false
    if reaper.PitchCanvasPrecision_SetTrackFXChoice(self.row.track,self.row.fx,enabled and 1 or 0)~=1 then self.notice='This instrument is excluded from Adaptive.';return end
    self.record.decision=enabled and 'Adaptive' or 'Off';store(self.record)
    self.notice=self.matching and 'Decision saved; applied to this instrument.' or 'Applied here; saved measurement was under previous conditions.'
  end
  function self:close()
    self:cancel()
    reaper.PitchCanvasPrecision_CheckListen(nil,0,-1)
    if valid(self.row) then reaper.PitchCanvasPrecision_CheckRelease(self.row.track,self.row.fx) end
    self.audioKey=nil
  end
  return self
end
M.hash=hash;M.pack=pack;M.unpack=unpackFields;M.readRecord=readRecord
return M

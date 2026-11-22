// Pure presentation logic over the real native projection, shared by ArkUI and offline checks.
export interface DeviceRow {
  key: string;
  current: boolean;
  participants?: string[] | null;
  participantToken?: string | null;
  wallpaperRevision?: string;
  wallpaperState?: string;
  fields: Record<string, string | number | boolean>;
}
export type DeviceControlState = 'active' | 'idle' | 'locally-ended' | 'stale' | 'unknown';
export interface DeviceCard {
  key: string;
  name: string;
  recordLabel: string;
  wallpaperRevision: string;
  wallpaperState: string;
  presence: string;
  statusLabel: string;
  controlState: DeviceControlState;
  controlLabel: string;
  participantToken: string;
  platformLabel: string;
  category: string;
  current: boolean;
  connectable: boolean;
  actionLabel: string;
  rank: number;
}
export const DEVICE_FRESH_MS: number = 60000;
export function listIsStale(updatedAt: number, failed: boolean, now: number): boolean {
  return failed || !(updatedAt > 0) || now < updatedAt || now - updatedAt >= DEVICE_FRESH_MS;
}
export function deviceName(row: DeviceRow): string {
  for (const field of ['alias', 'name', 'device_name']) {
    const value = row.fields[field];
    if (typeof value === 'string' && value.trim().length > 0) { return value.trim(); }
  }
  return '未命名设备';
}
export function devicePresence(row: DeviceRow): string {
  // Only these values have a pinned upstream meaning. Other values remain unknown.
  if (row.fields['status'] === 'CONNECTED') { return 'online'; }
  if (row.fields['status'] === 'DISCONNECTED') { return 'offline'; }
  return 'unknown';
}
function recordLabel(row: DeviceRow, rows: DeviceRow[]): string {
  if (!rows.some((other: DeviceRow) => other.key !== row.key && deviceName(other) === deviceName(row))) { return ''; }
  let length: number = 8;
  while (length < 64 && rows.some((other: DeviceRow) => other.key !== row.key && other.key.slice(0, length) === row.key.slice(0, length))) { length += 4; }
  return '同名设备 ' + row.key.slice(0, length).toUpperCase() + '，建议改名';
}
export function deviceCards(rows: DeviceRow[], stale: boolean, checkingEndedDevice:string=''): DeviceCard[] {
  const cards: DeviceCard[] = [];
  for (const row of rows) {
    if (!/^[a-f0-9]{64}$/.test(row.key) || cards.some((card: DeviceCard) => card.key === row.key)) { continue; }
    const presence: string = devicePresence(row);
    const platform=row.fields['platform'];
    const windows:boolean=platform===1;
    const category:string=row.fields['localMobile']===true?'mobile':platform===1||platform===4?'computer':platform===2||platform===3?'mobile':'unknown';
    const platformLabel:string=row.fields['previousMobile']===true?'历史本机手机或平板':row.fields['localMobile']===true?(row.fields['localDeviceType']==='tablet'?'本机平板':'本机手机'):platform===1?'Windows':platform===4?'Mac 电脑':platform===2?'安卓手机或平板':platform===3?'iPhone 或 iPad':platform===5?'电视':'设备类型未知';
    const connectable: boolean = !row.current && row.fields['previousMobile']!==true && windows && presence === 'online';
    let statusLabel: string = presence === 'online' ? '在线' : presence === 'offline' ? '离线' : '状态未知';
    const participants = row.participants;
    const onlyThisController=Array.isArray(participants)&&participants.length===1&&row.fields['localControllerOnly']===true;
    const control: { state: DeviceControlState; label: string } =
      row.key === checkingEndedDevice && onlyThisController ? { state: 'locally-ended', label: '本机已断开，等待服务端确认' } :
      stale ? { state: 'stale', label: '被控状态已过期' } :
      !Array.isArray(participants) ? { state: 'unknown', label: '被控状态未知' } :
      participants.length === 0 ? { state: 'idle', label: '未被控制' } :
      { state: 'active', label: '被控中 · 控制端：' + participants.map((name: string) => name.trim() || '名称未知').join('、') };
    const participantToken = control.state === 'active' && typeof row.participantToken === 'string' ? row.participantToken : '';
    cards.push({ key: row.key, controlState: control.state, controlLabel: control.label, participantToken: participantToken, name: deviceName(row), recordLabel: recordLabel(row, rows), wallpaperRevision: typeof row.wallpaperRevision === 'string' && /^[a-f0-9]{64}$/.test(row.wallpaperRevision) ? row.wallpaperRevision : '', wallpaperState: typeof row.wallpaperState==='string'?row.wallpaperState:'none', presence: presence,
      statusLabel: statusLabel, platformLabel: platformLabel, category:category, current: row.current,
      connectable: connectable, actionLabel: row.current ? '本机身份，无需连接' : !windows ? '暂不支持此设备' : presence === 'offline' ? '设备离线' : presence === 'unknown' ? '等待状态确认' : '进入远程桌面',
      rank: row.current ? 4 : presence === 'online' ? (windows ? 0 : 1) : presence === 'unknown' ? 2 : 3 });
  }
  return cards.sort((a: DeviceCard, b: DeviceCard) => a.rank - b.rank || a.name.localeCompare(b.name) || a.key.localeCompare(b.key));
}
export function visibleDeviceCards(cards:DeviceCard[],allDevices:boolean):DeviceCard[]{return allDevices?cards:cards.filter((card:DeviceCard)=>card.category==='computer'&&!card.current);}
export function selectionMatches(cards: DeviceCard[], key: string, name: string): boolean {
  return cards.some((card: DeviceCard) => card.key === key && card.name === name && card.connectable);
}
function two(value: number): string { return value.toString().padStart(2, '0'); }
export function refreshTimeLabel(updatedAt: number, now: number): string {
  if (!(updatedAt > 0)) { return '尚未成功更新'; }
  const date: Date = new Date(updatedAt);
  const current: Date = new Date(now);
  const prefix: string = date.getFullYear() === current.getFullYear() && date.getMonth() === current.getMonth() && date.getDate() === current.getDate()
    ? '' : (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日 ';
  return '上次更新 ' + prefix + two(date.getHours()) + ':' + two(date.getMinutes()) + ':' + two(date.getSeconds());
}

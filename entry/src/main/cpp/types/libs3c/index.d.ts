export const invoke: (input: string, expectRegisteredIdentity?: boolean) => Promise<string>;

export interface VideoStageResult {
  stage: string;
  code: number | null;
  atMs: number;
}
export interface VideoAttempt {
  name: string;
  hardware: boolean;
  pixelPolicy: string;
}
export interface VideoCleanup {
  stopCode: number | null;
  destroyCode: number | null;
  callbackCode: number | null;
  windowReleased: boolean;
  complete: boolean;
}
export interface VideoCapability {
  category: string;
  available: boolean;
  name?: string;
  hardware?: boolean;
  supports720p?: boolean;
  pixelQueryCode?: number;
  pixelFormats?: number[] | null;
  profileQueryCode?: number;
  profiles?: number[] | null;
  listsTruncated?: boolean;
  widthRangeCode?: number;
  widthRange?: number[] | null;
  heightRangeCode?: number;
  heightRange?: number[] | null;
  frameRateCode?: number;
  frameRate720?: number[] | null;
  widthAlignment?: number | null;
  heightAlignment?: number | null;
}
// JSON returned by videoStatus and by the startVideo completion Promise.
// ready means Start succeeded; firstRender means a buffer was submitted to Surface.
// A recovered bounded fallback can have error=0 with non-null firstError/failureStage.
export interface VideoState {
  renderSlot?: number;
  generation?: number;
  legacyMode?: boolean;
  ready: boolean;
  phase: string;
  error: number;
  starting?: boolean;
  running?: boolean;
  released?: boolean;
  failureStage?: string | null;
  firstError?: number | null;
  systemCode?: number | null;
  failureKind?: string | null;
  recovered?: boolean;
  cancelled?: boolean;
  stopRequested?: boolean;
  windowCreated?: boolean;
  windowWidth?: number;
  windowHeight?: number;
  codecName?: string | null;
  hardware?: boolean | null;
  pixelPolicy?: string;
  pixelFormat?: number | null;
  attemptCount?: number;
  attempts?: VideoAttempt[];
  stages?: VideoStageResult[];
  capabilities?: VideoCapability[];
  au?: number;
  accepted?: number;
  submitted?: number;
  decoded?: number;
  rendered?: number;
  width?: number;
  height?: number;
  firstAccessUnit?: boolean;
  firstSps?: boolean;
  firstPps?: boolean;
  firstIdr?: boolean;
  firstDecode?: boolean;
  firstRender?: boolean;
  streamProfileIdc?: number | null;
  streamLevelIdc?: number | null;
  eos?: boolean;
  cleanup?: VideoCleanup;
  reusable?: boolean;
}
// Promise completes after native worker cleanup, not when decoder becomes ready.
export const startVideo: (surfaceId: string, codec?: number) => Promise<string>;
export const videoStatus: () => string;
// Graceful EOS drain is bounded to 1000ms, then cleanup on the worker thread.
export const stopVideo: () => void;
// Cancel initialization/drain at the next worker checkpoint; never waits for EOS.
// A synchronous system SDK call cannot be safely forcibly interrupted.
export const hardStopVideo: () => void;
export const videoCapabilities: () => string;
// Exact active-decoder query; false also covers absent/initializing decoder.
export const videoSizeSupport: (width: number, height: number) => string;
export const videoMetrics: () => string;

// Renderer slots are 0/1, independent of remote track indexes. Native generation
// is a positive process-lifetime uint32; never generate or reuse it in ArkTS.
export const reserveVideoSlot: (slot: number) => number;
// Consumes one reservation. Promise completes after cleanup; poll matching status
// for ready/firstRender. Moving Surface requires cleanup and a new reservation.
export const startVideoSlot: (slot: number, generation: number, surfaceId: string, codec?: number) => Promise<string>;
export const videoSlotStatus: (slot: number, generation: number) => string;
export const videoSlotMetrics: (slot: number, generation: number) => string;
export const videoSlotSizeSupport: (slot: number, generation: number, width: number, height: number) => string;
export const stopVideoSlot: (slot: number, generation: number) => void;
export const hardStopVideoSlot: (slot: number, generation: number) => void;
// Room-owner teardown only; child closure must stop its exact slot/generation.
export const stopAllVideos: (hard: boolean) => void;

export const audioConfigure: (config: string) => string;
export const audioStatus: () => string;
export const audioStop: () => string;

// No secret getter. Binding comes only from the current native authenticated owned peer.
export const windowsUnlockEnroll: (password: string) => Promise<string>;
export const windowsUnlockStatus: () => Promise<string>;
export const windowsUnlockSetEnabled: (enabled: boolean) => Promise<string>;
export const windowsUnlockDelete: () => Promise<string>;
export const windowsUnlockUse: () => Promise<string>;

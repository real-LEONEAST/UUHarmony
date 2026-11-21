// This adapter is dynamically imported only on PC. Native namespaces are static
// inside the lazy module, so their exports have the same shape on every runtime.
import { initialize,adoptLegacyAccount,bindSharedAccount,clearSharedAccount,getState,
  startCapture,startHost,configureDisplay,stopCaptureAsync,stopAsync,requestInput,setAssistanceEnabled,resetAssistanceCode,publishDeviceCover } from 'libuuhost.so';
import type { HostNative } from './PcHostService';
export const hostNative:HostNative={initialize:initialize,adoptLegacyAccount:adoptLegacyAccount,
  bindSharedAccount:bindSharedAccount,clearSharedAccount:clearSharedAccount,getState:getState,
  startCapture:startCapture,startHost:startHost,configureDisplay:configureDisplay,stopCaptureAsync:stopCaptureAsync,stopAsync:stopAsync,requestInput:requestInput,
  setAssistanceEnabled:setAssistanceEnabled,resetAssistanceCode:resetAssistanceCode,publishDeviceCover:publishDeviceCover};

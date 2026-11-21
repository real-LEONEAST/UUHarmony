import { isReceivingFiles, setReceivingFiles } from 'libuuhost.so';

export interface PcReceiveNative {
  isReceiving: () => boolean;
  setReceiving: (enabled: boolean, directoryFd?: number, root?: string) => Promise<number>;
}

export const receiveNative: PcReceiveNative = {
  isReceiving: isReceivingFiles,
  setReceiving: setReceivingFiles
};

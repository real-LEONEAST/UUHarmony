// SPDX-License-Identifier: GPL-3.0-only
// Explicitly started after ArkTS permission + remote mic negotiation. No networking.
#include <napi/native_api.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiocapturer.h>
#include <opus.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>
namespace {
constexpr size_t kFrames=960, kMaxPackets=10, kMaxPacket=4000;
constexpr double kMaxGeneration=9007199254740991.0;
struct Packet {std::vector<uint8_t> bytes;uint64_t timestamp=0;};
std::mutex lifecycle, dataMutex;
OH_AudioStreamBuilder* builder=nullptr;
OH_AudioCapturer* capturer=nullptr;
OpusEncoder* encoder=nullptr;
std::atomic<bool> accepting{false};
std::atomic<int> lastError{0};
std::atomic<int> lastInterrupt{0};
uint64_t generation=0, clockSamples=0, dropped=0;
int channels=1;
std::vector<opus_int16> pcm;
std::deque<Packet> packets;
bool Check(OH_AudioStream_Result result){if(result==AUDIOSTREAM_SUCCESS)return true;lastError.store(static_cast<int>(result));return false;}
void ReadData(OH_AudioCapturer*,void*,void* buffer,int32_t bytes){
 if(!accepting.load(std::memory_order_acquire)||!buffer||bytes<=0||bytes>384000)return;
 std::lock_guard<std::mutex> lock(dataMutex);
 if(!accepting.load(std::memory_order_acquire)||!encoder||bytes%(channels*2))return;
 const size_t frameSamples=kFrames*static_cast<size_t>(channels), incoming=static_cast<size_t>(bytes)/2;
 // Process bounded chunks; never retain over 20ms of unencoded PCM.
 const auto* input=static_cast<const uint8_t*>(buffer);
 size_t consumed=0;
 while(consumed<incoming){
  const size_t count=std::min(frameSamples-pcm.size(),incoming-consumed), old=pcm.size();pcm.resize(old+count);
  std::memcpy(pcm.data()+old,input+consumed*2,count*2);consumed+=count;
  if(pcm.size()!=frameSamples)continue;
  uint8_t output[kMaxPacket];const int size=opus_encode(encoder,pcm.data(),static_cast<int>(kFrames),output,sizeof(output));pcm.clear();
  const uint64_t timestamp=clockSamples;clockSamples+=kFrames;
  if(size<=0){lastError.store(size?size:-1);accepting.store(false,std::memory_order_release);packets.clear();return;}
  if(packets.size()>=kMaxPackets){packets.pop_front();++dropped;}
  packets.push_back({std::vector<uint8_t>(output,output+size),timestamp});
 }
}
void Interrupt(OH_AudioCapturer*,void*,OH_AudioInterrupt_ForceType,OH_AudioInterrupt_Hint hint){
 lastInterrupt.store(static_cast<int>(hint));
 // An interruption always requires another explicit UI start; never auto-resume recording.
 accepting.store(false,std::memory_order_release);lastError.store(-1004);
}
void Error(OH_AudioCapturer*,void*,OH_AudioStream_Result error){accepting.store(false,std::memory_order_release);lastError.store(static_cast<int>(error));}
void StopLocked(){
 accepting.store(false,std::memory_order_release);
 // Never hold dataMutex across OHAudio stop/release: these may wait on ReadData.
 if(capturer){OH_AudioCapturer_Stop(capturer);if(Check(OH_AudioCapturer_Release(capturer)))capturer=nullptr;}
 if(builder&&!capturer){if(Check(OH_AudioStreamBuilder_Destroy(builder)))builder=nullptr;}
 std::lock_guard<std::mutex> lock(dataMutex);
 if(encoder){opus_encoder_destroy(encoder);encoder=nullptr;}pcm.clear();packets.clear();clockSamples=0;dropped=0;generation=0;
}
std::string StatusLocked(){
 std::lock_guard<std::mutex> lock(dataMutex);
 return std::string("{\"running\":")+(accepting.load()?"true":"false")+",\"generation\":"+std::to_string(generation)+",\"error\":"+std::to_string(lastError.load())+",\"interrupt\":"+std::to_string(lastInterrupt.load())+",\"channels\":"+std::to_string(channels)+",\"sampleRate\":48000,\"samples\":960,\"packetMs\":20,\"queued\":"+std::to_string(packets.size())+",\"dropped\":"+std::to_string(dropped)+",\"cleanupPending\":"+((capturer&&!accepting.load())?"true":"false")+"}";
}
std::string Start(uint64_t nextGeneration,bool stereo){
 std::lock_guard<std::mutex> control(lifecycle);StopLocked();lastError.store(0);lastInterrupt.store(0);
 if(capturer||builder){lastError.store(-1001);return StatusLocked();}
 channels=stereo?2:1;
 int error=0;encoder=opus_encoder_create(48000,channels,OPUS_APPLICATION_VOIP,&error);
 if(!encoder||error!=OPUS_OK){lastError.store(error?error:-1002);StopLocked();return StatusLocked();}
 if(opus_encoder_ctl(encoder,OPUS_SET_BITRATE(stereo?96000:64000))!=OPUS_OK||opus_encoder_ctl(encoder,OPUS_SET_INBAND_FEC(1))!=OPUS_OK||opus_encoder_ctl(encoder,OPUS_SET_PACKET_LOSS_PERC(10))!=OPUS_OK){lastError.store(-1002);StopLocked();return StatusLocked();}
 {
  std::lock_guard<std::mutex> lock(dataMutex);generation=nextGeneration;pcm.reserve(kFrames*channels);
 }
 bool ok=Check(OH_AudioStreamBuilder_Create(&builder,AUDIOSTREAM_TYPE_CAPTURER));
 if(ok)ok=Check(OH_AudioStreamBuilder_SetSamplingRate(builder,48000))&&Check(OH_AudioStreamBuilder_SetChannelCount(builder,channels))&&
  Check(OH_AudioStreamBuilder_SetSampleFormat(builder,AUDIOSTREAM_SAMPLE_S16LE))&&Check(OH_AudioStreamBuilder_SetEncodingType(builder,AUDIOSTREAM_ENCODING_TYPE_RAW))&&
  Check(OH_AudioStreamBuilder_SetLatencyMode(builder,AUDIOSTREAM_LATENCY_MODE_NORMAL))&&Check(OH_AudioStreamBuilder_SetCapturerInfo(builder,AUDIOSTREAM_SOURCE_TYPE_MIC))&&
  Check(OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder,ReadData,nullptr))&&Check(OH_AudioStreamBuilder_SetCapturerInterruptCallback(builder,Interrupt,nullptr))&&
  Check(OH_AudioStreamBuilder_SetCapturerErrorCallback(builder,Error,nullptr))&&Check(OH_AudioStreamBuilder_GenerateCapturer(builder,&capturer));
 int32_t rate=0,count=0;OH_AudioStream_SampleFormat format=AUDIOSTREAM_SAMPLE_U8;
 if(ok)ok=Check(OH_AudioCapturer_GetSamplingRate(capturer,&rate))&&Check(OH_AudioCapturer_GetChannelCount(capturer,&count))&&Check(OH_AudioCapturer_GetSampleFormat(capturer,&format));
 if(ok&&(rate!=48000||count!=channels||format!=AUDIOSTREAM_SAMPLE_S16LE)){lastError.store(-1003);ok=false;}
 if(ok){accepting.store(true,std::memory_order_release);ok=Check(OH_AudioCapturer_Start(capturer));}
 if(!ok)StopLocked();
 return StatusLocked();
}
std::string Base64(const std::vector<uint8_t>& bytes){
 static constexpr char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
 std::string out;out.reserve(((bytes.size()+2)/3)*4);
 for(size_t i=0;i<bytes.size();i+=3){uint32_t n=static_cast<uint32_t>(bytes[i])<<16;if(i+1<bytes.size())n|=static_cast<uint32_t>(bytes[i+1])<<8;if(i+2<bytes.size())n|=bytes[i+2];out.push_back(alphabet[n>>18]);out.push_back(alphabet[(n>>12)&63]);out.push_back(i+1<bytes.size()?alphabet[(n>>6)&63]:'=');out.push_back(i+2<bytes.size()?alphabet[n&63]:'=');}return out;
}
napi_value Text(napi_env env,const std::string& text){napi_value result=nullptr;napi_create_string_utf8(env,text.c_str(),text.size(),&result);return result;}
napi_value StartNapi(napi_env env,napi_callback_info info){
 napi_value args[3];size_t count=3;napi_get_cb_info(env,info,&count,args,nullptr,nullptr);double value=0;bool stereo=false;double packetMs=0;
 if(count!=3||napi_get_value_double(env,args[0],&value)!=napi_ok||!std::isfinite(value)||std::floor(value)!=value||value<1||value>kMaxGeneration||napi_get_value_bool(env,args[1],&stereo)!=napi_ok||napi_get_value_double(env,args[2],&packetMs)!=napi_ok||packetMs!=20){std::lock_guard<std::mutex> lock(lifecycle);StopLocked();lastError.store(-1000);return Text(env,StatusLocked());}
 return Text(env,Start(static_cast<uint64_t>(value),stereo));
}
napi_value ReadNapi(napi_env env,napi_callback_info){
 Packet packet;uint64_t current=0;bool available=false;int error=0;
 {std::lock_guard<std::mutex> lock(dataMutex);current=generation;error=lastError.load();if(accepting.load()&&!packets.empty()){packet=std::move(packets.front());packets.pop_front();available=true;}else if(!accepting.load()){packets.clear();pcm.clear();}}
 return Text(env,std::string("{\"generation\":")+std::to_string(current)+",\"available\":"+(available?"true":"false")+",\"base64\":\""+(available?Base64(packet.bytes):"")+"\",\"timestamp\":"+std::to_string(packet.timestamp)+",\"samples\":960,\"error\":"+std::to_string(error)+"}");
}
napi_value StopNapi(napi_env env,napi_callback_info){std::lock_guard<std::mutex> lock(lifecycle);StopLocked();napi_value result;napi_get_undefined(env,&result);return result;}
napi_value StatusNapi(napi_env env,napi_callback_info){std::lock_guard<std::mutex> lock(lifecycle);return Text(env,StatusLocked());}
void Cleanup(void*){std::lock_guard<std::mutex> lock(lifecycle);StopLocked();}
napi_value Init(napi_env env,napi_value exports){napi_add_env_cleanup_hook(env,Cleanup,nullptr);napi_property_descriptor properties[]={
 {"start",nullptr,StartNapi,nullptr,nullptr,nullptr,napi_default,nullptr},{"read",nullptr,ReadNapi,nullptr,nullptr,nullptr,napi_default,nullptr},
 {"stop",nullptr,StopNapi,nullptr,nullptr,nullptr,napi_default,nullptr},{"status",nullptr,StatusNapi,nullptr,nullptr,nullptr,napi_default,nullptr}};
 napi_define_properties(env,exports,sizeof(properties)/sizeof(properties[0]),properties);return exports;}
napi_module module={1,0,nullptr,Init,"uumic",nullptr,{0}};
}
extern "C" __attribute__((constructor)) void RegisterMicrophoneModule(){napi_module_register(&module);}

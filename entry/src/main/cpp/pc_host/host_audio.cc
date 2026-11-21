// System playback only; the capture consent owns this pipeline. No microphone.
#include <opus.h>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>
namespace {std::mutex guard;OpusEncoder* encoder=nullptr;std::vector<opus_int16> pcm;std::deque<std::vector<unsigned char>> packets;uint64_t encoded=0;constexpr size_t samples=1920;}
extern "C" int uu_host_audio_prepare(bool enabled){
 std::lock_guard<std::mutex> lock(guard);if(encoder){opus_encoder_destroy(encoder);encoder=nullptr;}pcm.clear();packets.clear();encoded=0;if(!enabled)return 0;
 int error=0;encoder=opus_encoder_create(48000,2,OPUS_APPLICATION_RESTRICTED_LOWDELAY,&error);if(!encoder||error!=OPUS_OK)return -1;
 if(opus_encoder_ctl(encoder,OPUS_SET_BITRATE(128000))!=OPUS_OK){opus_encoder_destroy(encoder);encoder=nullptr;return -1;}return 0;
}
extern "C" bool uu_host_audio_enabled(){std::lock_guard<std::mutex> lock(guard);return encoder!=nullptr;}
extern "C" void uu_host_audio_pcm(const unsigned char* data,size_t size){
 if(!data||!size||size>384000||size%4)return;std::lock_guard<std::mutex> lock(guard);if(!encoder)return;
 if(pcm.size()+size/2>samples*5)pcm.clear();size_t old=pcm.size();pcm.resize(old+size/2);std::memcpy(pcm.data()+old,data,size);
 while(pcm.size()>=samples){unsigned char bytes[4000];int count=opus_encode(encoder,pcm.data(),960,bytes,sizeof(bytes));pcm.erase(pcm.begin(),pcm.begin()+samples);if(count>0){++encoded;if(packets.size()>=25)packets.pop_front();packets.emplace_back(bytes,bytes+count);}}
}
extern "C" int uu_host_audio_poll(unsigned char* data,size_t capacity){std::lock_guard<std::mutex> lock(guard);if(!encoder)return -1;if(packets.empty())return 0;const auto& next=packets.front();if(next.size()>capacity)return -1;int size=next.size();std::memcpy(data,next.data(),size);packets.pop_front();return size;}

extern "C" uint64_t uu_host_audio_frames(){std::lock_guard<std::mutex> lock(guard);return encoded;}

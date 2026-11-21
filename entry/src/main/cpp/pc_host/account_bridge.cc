#include <asset/asset_api.h>
#include <napi/native_api.h>
#include <string>
#include <cstdint>
extern "C" {
int uu_unified_bind(const char*, const char*);
int uu_unified_export_slot(unsigned, uint8_t*, size_t);
int uu_unified_recover_viewer_identity(const char*, uint8_t*, size_t);
int uu_unified_unbind();
}
namespace {
void Wipe(std::string& s) { volatile char* p = s.data(); for(size_t i=0;i<s.size();++i) p[i]=0; s.clear(); }
Asset_Attr Blob(uint32_t tag, const std::string& s) { Asset_Attr a{}; a.tag=tag; a.value.blob={static_cast<uint32_t>(s.size()),reinterpret_cast<uint8_t*>(const_cast<char*>(s.data()))}; return a; }
Asset_Attr Number(uint32_t tag,uint32_t n) { Asset_Attr a{}; a.tag=tag; a.value.u32=n; return a; }
int Read(const std::string& alias,std::string& out) {
  Asset_Attr q[]={Blob(ASSET_TAG_ALIAS,alias),Number(ASSET_TAG_RETURN_TYPE,ASSET_RETURN_ALL)};
  Asset_ResultSet rows{}; int rc=OH_Asset_Query(q,2,&rows); if(rc==ASSET_NOT_FOUND) return 1; if(rc) return -1;
  int result=-1;
  if(rows.count==1) { auto* a=OH_Asset_ParseAttr(&rows.results[0],ASSET_TAG_SECRET);
    if(a && a->value.blob.size>0 && a->value.blob.size<=1024) { out.assign(reinterpret_cast<char*>(a->value.blob.data),a->value.blob.size); if(out.find('\0')==std::string::npos) result=0; }
  }
  OH_Asset_FreeResultSet(&rows); return result;
}
int Put(const std::string& alias,const std::string& value) {
  Asset_Attr q=Blob(ASSET_TAG_ALIAS,alias),secret=Blob(ASSET_TAG_SECRET,value);
  int rc=OH_Asset_Update(&q,1,&secret,1);
  if(rc==ASSET_NOT_FOUND) { Asset_Attr a[]={q,secret,Number(ASSET_TAG_ACCESSIBILITY,ASSET_ACCESSIBILITY_DEVICE_UNLOCKED),Number(ASSET_TAG_SYNC_TYPE,ASSET_SYNC_TYPE_NEVER)}; rc=OH_Asset_Add(a,4); }
  return rc? -1:0;
}
int RestoreMissingIdentity(const std::string& account, const std::string& alias) {
  uint8_t bytes[1024]{};
  const int size=uu_unified_recover_viewer_identity(account.c_str(),bytes,sizeof(bytes));
  int result=size;
  if(size>0) {
    std::string identity(reinterpret_cast<char*>(bytes),size);
    result=Put(alias,identity)==0?1:-1;
    Wipe(identity);
  }
  volatile uint8_t* p=bytes;for(size_t i=0;i<sizeof(bytes);++i)p[i]=0;
  return result;
}
napi_value Code(napi_env env,int code) { napi_value v; napi_create_int32(env,code,&v); return v; }
const std::string kIdentity="uus3c.identity.v1",kAccount="uus3c.account.v1";
napi_value Bind(napi_env env,napi_callback_info) {
  std::string account,identity; int result=-1;
  if(Read(kAccount,account)==0 && Read(kIdentity,identity)==0) result=uu_unified_bind(account.c_str(),identity.c_str());
  Wipe(account);Wipe(identity);return Code(env,result);
}
napi_value Adopt(napi_env env,napi_callback_info) {
  std::string savedAccount,savedIdentity;
  const int accountState=Read(kAccount,savedAccount);
  const int identityState=accountState==0?Read(kIdentity,savedIdentity):1;
  const int restored=accountState==0&&identityState==1?RestoreMissingIdentity(savedAccount,kIdentity):0;
  Wipe(savedAccount);Wipe(savedIdentity);
  if(restored<0||accountState<0||identityState<0)return Code(env,-1);
  // Before the controller's first boot, adopt the old PC package only if no viewer account exists.
  const std::string marker="UUHarmony.Unified.LegacyAdopted.v1";
  std::string account,identity,previous,done;
  int checked=Read(marker,done);Wipe(done);
  if(checked!=1) return Code(env,checked==0?1:-1);
  int read=Read(kAccount,account);
  if(read!=1) { Wipe(account);return Code(env,read==0?(Put(marker,"1")==0?1:-1):-1); }
  uint8_t bytes[1024]{}; int n=uu_unified_export_slot(0,bytes,sizeof(bytes));
  if(n<=0) return Code(env,n==0?(Put(marker,"1")==0?1:-1):-1);
  identity.assign(reinterpret_cast<char*>(bytes),n);
  n=uu_unified_export_slot(1,bytes,sizeof(bytes));
  if(n>0) account.assign(reinterpret_cast<char*>(bytes),n);
  volatile uint8_t* p=bytes; for(size_t i=0;i<sizeof(bytes);++i) p[i]=0;
  int result=-1;
  if(n>0) {
    int old=Read(kIdentity,previous);
    // Keep the previous viewer identity locally; never delete or mutate any cloud registration.
    if(old>=0 && (old==1 || previous==identity || Put("UUHarmony.Unified.PreviousViewerIdentity.v1",previous)==0)) {
      if(Put(kIdentity,identity)==0) result=Put(kAccount,account);
    }
  }
  if(result==0) result=Put(marker,"1");
  Wipe(account);Wipe(identity);Wipe(previous);return Code(env,result);
}
napi_value Unbind(napi_env env,napi_callback_info) { return Code(env,uu_unified_unbind()); }
}
void UnifiedAccountExports(napi_env env,napi_value exports) {
  napi_property_descriptor p[]={
    {"bindSharedAccount",nullptr,Bind,nullptr,nullptr,nullptr,napi_default,nullptr},
    {"adoptLegacyAccount",nullptr,Adopt,nullptr,nullptr,nullptr,napi_default,nullptr},
    {"clearSharedAccount",nullptr,Unbind,nullptr,nullptr,nullptr,napi_default,nullptr}};
  napi_define_properties(env,exports,3,p);
}

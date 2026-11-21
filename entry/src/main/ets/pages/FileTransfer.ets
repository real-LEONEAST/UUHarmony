import { SharedFileTransfer } from './SharedFileTransfer';

@Entry
@Component
struct FileTransfer {
  @State private browsing:boolean=false;
  onBackPress():boolean{if(this.browsing){this.browsing=false;return true;}return false;}
  build(){
    Column(){ SharedFileTransfer({browsing:$browsing}) }.width('100%').height('100%')
  }
}

import { Phase } from '../service/CommonEvents';
import { ConfigStore } from '../service/ConfigStore';
import { VpnController } from '../service/VpnController';
import { buildXrayConfig } from '../service/XrayConfig';

const PHASE_TEXT: Record<string, string> = {
  'DISCONNECTED': '未连接',
  'CONNECTING': '连接中',
  'CONNECTED': '已连接',
  'STOPPING': '断开中',
  'ERROR': '出错',
};

const PHASE_COLOR: Record<string, string> = {
  'DISCONNECTED': '#5F6368',
  'CONNECTING': '#FF9500',
  'CONNECTED': '#34C759',
  'STOPPING': '#FF9500',
  'ERROR': '#FF3B30',
};

@Entry
@Component
struct Index {
  @StorageLink('vpnPhase') phase: Phase = 'DISCONNECTED';
  @StorageLink('vpnInfo') info: string = '';
  @StorageLink('vpnLogs') logs: string[] = [];
  @StorageLink('xrayVersion') version: string = '';
  @State config: string = '';
  private logScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.config = ConfigStore.load();
  }

  private busy(): boolean {
    return this.phase === 'CONNECTING' || this.phase === 'STOPPING';
  }

  private async onConnect(): Promise<void> {
    try {
      // Validate here so mistakes show up before the VPN is touched.
      buildXrayConfig(this.config);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: (e as Error).message, duration: 4000 });
      return;
    }
    await ConfigStore.save(this.config);
    await VpnController.connect(this.config);
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Circle({ width: 12, height: 12 }).fill(PHASE_COLOR[this.phase] ?? '#5F6368')
        Text(PHASE_TEXT[this.phase] ?? this.phase).fontSize(20).fontWeight(FontWeight.Medium)
        Text(this.info).fontSize(14).fontColor('#5F6368').layoutWeight(1).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.phase === 'CONNECTED' || this.phase === 'CONNECTING' || this.phase === 'STOPPING') {
          Button('断开').enabled(this.phase !== 'STOPPING').onClick((): void => {
            VpnController.disconnect();
          })
        } else {
          Button('连接').enabled(this.config.trim().length > 0).onClick((): void => {
            this.onConnect();
          })
        }
      }.width('100%')

      Text('Xray 配置（JSON）').fontSize(14).fontColor('#5F6368').width('100%')
      TextArea({ text: this.config, placeholder: '粘贴完整的 Xray JSON 配置：至少包含 outbounds。TUN 入站和 DNS 会自动补上。' })
        .fontFamily('monospace')
        .fontSize(13)
        .height('40%')
        .enabled(!this.busy() && this.phase !== 'CONNECTED')
        .onChange((v: string): void => { this.config = v; })

      Row() {
        Text(`日志${this.version ? '  ·  Xray ' + this.version : ''}`).fontSize(14).fontColor('#5F6368')
          .layoutWeight(1)
        Button('清空').fontSize(12).height(28).backgroundColor('#E8EAED').fontColor('#111418')
          .onClick((): void => VpnController.clearLogs())
      }.width('100%')

      List({ scroller: this.logScroller }) {
        ForEach(this.logs, (line: string, i: number) => {
          ListItem() {
            Text(line).fontFamily('monospace').fontSize(12).copyOption(CopyOptions.LocalDevice)
          }
        }, (line: string, i: number): string => `${i}:${line}`)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#F1F3F5')
      .borderRadius(8)
      .padding(8)
      .onAppear((): void => this.logScroller.scrollEdge(Edge.Bottom))
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}

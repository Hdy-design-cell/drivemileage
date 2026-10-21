import { geoLocationManager } from '@kit.LocationKit';
import { DistanceUtil } from '../utils/DistanceUtil';
import { DbHelper, DriveRecord } from '../common/DbHelper';
import { common, abilityAccessCtrl, wantAgent, WantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State currentDistance: number = 0;
  // 三态：0=空闲 1=行驶中 2=已暂停
  @State driveStatus: number = 0;
  @State isAgreedPrivacy: boolean = false;
  @State dayTotal: number = 0;
  @State weekTotal: number = 0;
  @State monthTotal: number = 0;
  @State yearTotal: number = 0;
  @State recordList: DriveRecord[] = [];
  // 定位信息显示
  @State debugLocation: string = '正在获取定位...';
  @State debugCoord: string = '';
  // 重命名编辑状态
  @State editingId: number = -1;
  @State editName: string = '';

  private lastLocation: geoLocationManager.Location | null = null;
  private locationCallback: Callback<geoLocationManager.Location> | null = null;
  private startTime: number = 0;
  // 暂停计时：累计暂停总时长 + 当前暂停开始时刻
  private totalPausedTime: number = 0;
  private pauseStartTime: number = 0;
  // 分段时间记录：每一段 [开始时间戳, 结束时间戳]，结束为0表示正在进行中
  private segments: number[][] = [];
  // 分段里程记录：每一段开了多少公里
  private segDistances: number[] = [];
  private segmentStartDistance: number = 0; // 当前段开始时的累计里程

  aboutToAppear() {
    const context = getContext(this) as common.UIAbilityContext;
    DbHelper.init(context).catch((err: Error) => {
      console.error('数据库初始化失败: ' + err.message);
    });
    this.checkPrivacyAgreed();
  }

  private async checkPrivacyAgreed() {
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(getContext(this), 'privacy_store');
      const agreed: boolean = pref.getSync('privacyAgreed', false) as boolean;
      if (agreed) {
        this.isAgreedPrivacy = true;
        this.requestPermission();
        this.preheatGps();
        this.loadStatistics();
        this.loadHistory();
        this.checkDriveState();
      }
    } catch (err) {
      console.error('读取隐私同意状态失败: ' + JSON.stringify(err));
    }
  }

  private agreePrivacy() {
    this.isAgreedPrivacy = true;
    this.savePrivacyAgreed();
    this.requestPermission();
    this.preheatGps();
    this.loadStatistics();
    this.loadHistory();
  }

  private async savePrivacyAgreed() {
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(getContext(this), 'privacy_store');
      pref.putSync('privacyAgreed', true);
      await pref.flush();
    } catch (err) {
      console.error('保存隐私同意状态失败: ' + JSON.stringify(err));
    }
  }

  // ===== 行程存档：防止App被杀后里程丢失 =====
  private async saveDriveState() {
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(getContext(this), 'drive_state_store');
      const state: string = JSON.stringify({
        driveStatus: this.driveStatus,
        currentDistance: this.currentDistance,
        startTime: this.startTime,
        totalPausedTime: this.totalPausedTime,
        pauseStartTime: this.pauseStartTime,
        segments: this.segments,
        segDistances: this.segDistances,
        segmentStartDistance: this.segmentStartDistance
      });
      pref.putSync('driveState', state);
      await pref.flush();
    } catch (err) {
      console.error('保存行程存档失败: ' + JSON.stringify(err));
    }
  }

  private async clearDriveState() {
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(getContext(this), 'drive_state_store');
      pref.deleteSync('driveState');
      await pref.flush();
    } catch (err) {
      console.error('清除行程存档失败: ' + JSON.stringify(err));
    }
  }

  // 启动时检查有没有未完成的行程存档
  private async checkDriveState() {
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(getContext(this), 'drive_state_store');
      const stateStr: string = pref.getSync('driveState', '') as string;
      if (stateStr.length === 0) {
        return;
      }
      const state: Record<string, Object> = JSON.parse(stateStr);
      this.getUIContext().getPromptAction().showDialog({
        title: '恢复行程',
        message: '检测到上次有未结束的行程（' + (state['currentDistance'] as number).toFixed(2) + ' 公里），是否恢复继续计程？',
        buttons: [
          { text: '放弃', color: '#999999' },
          { text: '恢复', color: '#007DFF' }
        ]
      }).then((result) => {
        if (result.index === 1) {
          this.restoreDriveState(state);
        } else {
          this.clearDriveState();
        }
      });
    } catch (err) {
      console.error('读取行程存档失败: ' + JSON.stringify(err));
    }
  }

  // 恢复行程状态
  private restoreDriveState(state: Record<string, Object>) {
    this.driveStatus = state['driveStatus'] as number;
    this.currentDistance = state['currentDistance'] as number;
    this.startTime = state['startTime'] as number;
    this.totalPausedTime = state['totalPausedTime'] as number;
    this.pauseStartTime = state['pauseStartTime'] as number;
    this.segments = state['segments'] as number[][];
    this.segDistances = state['segDistances'] as number[];
    this.segmentStartDistance = state['segmentStartDistance'] as number;
    this.lastLocation = null;
    if (this.driveStatus === 1) {
      // 上次是行驶中被杀，重新启动定位继续计
      this.debugLocation = '正在恢复定位...';
      this.resumeLocationUpdates();
      this.startBackgroundRunning();
    } else if (this.driveStatus === 2) {
      this.debugLocation = '已暂停，点击继续恢复计程';
    }
  }

  // 重新启动定位回调（恢复存档用）
  private resumeLocationUpdates() {
    const request: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: 1,
      distanceInterval: 0,
      maxAccuracy: 0
    };
    const self = this;
    const callback: Callback<geoLocationManager.Location> = (location: geoLocationManager.Location): void => {
      self.debugLocation = '定位精度 ' + location.accuracy.toFixed(0) + ' 米 · ' + self.formatAccuracy(location.accuracy);
      self.debugCoord = location.latitude.toFixed(6) + ', ' + location.longitude.toFixed(6);
      if (location.accuracy > 100) {
        return;
      }
      if (self.lastLocation) {
        const dist: number = DistanceUtil.calculateDistance(
          self.lastLocation.latitude, self.lastLocation.longitude,
          location.latitude, location.longitude
        );
        if (dist > 0.001) {
          self.currentDistance = Math.round((self.currentDistance + dist) * 1000) / 1000;
          self.saveDriveState();
        }
      }
      self.lastLocation = location;
    };
    this.locationCallback = callback;
    try {
      geoLocationManager.on('locationChange', request, callback);
    } catch (err) {
      this.driveStatus = 0;
      this.getUIContext().getPromptAction().showToast({ message: '恢复定位失败，请重新开始行程' });
    }
  }

  private refusePrivacy() {
    this.getUIContext().getPromptAction().showToast({ message: '需要同意隐私政策后才能使用本应用' });
  }

  private async requestPermission() {
    const context = getContext(this) as common.UIAbilityContext;
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    try {
      await atManager.requestPermissionsFromUser(context, [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ]);
    } catch (err) {
      console.error('权限申请失败: ' + JSON.stringify(err));
    }
  }

  private preheatGps() {
    const request: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: 1,
      distanceInterval: 0,
      maxAccuracy: 0
    };
    geoLocationManager.getCurrentLocation(request).then((location: geoLocationManager.Location): void => {
      console.info('GPS预热完成: ' + location.latitude + ',' + location.longitude);
      this.debugLocation = '定位已就绪，说走就走';
    }).catch((err: Error): void => {
      console.error('GPS预热失败: ' + JSON.stringify(err));
    });
  }

  private formatAccuracy(accuracy: number): string {
    if (accuracy <= 10) {
      return '信号极佳';
    } else if (accuracy <= 30) {
      return '信号良好';
    } else if (accuracy <= 100) {
      return '信号一般';
    } else {
      return '信号较弱';
    }
  }

  private async startBackgroundRunning() {
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.hou.drivemileage',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        getContext(this),
        backgroundTaskManager.BackgroundMode.LOCATION,
        wantAgentObj
      );
      console.info('后台定位任务已启动');
      this.getUIContext().getPromptAction().showToast({ message: '后台定位已开启，切后台也能计里程' });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      console.error('后台定位任务申请失败: ' + JSON.stringify(err));
      this.getUIContext().getPromptAction().showToast({ message: `后台定位开启失败，错误码 ${e.code}` });
    }
  }

  private async stopBackgroundRunning() {
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
      console.info('后台定位任务已停止');
    } catch (err) {
      console.error('后台定位任务停止失败: ' + JSON.stringify(err));
    }
  }

  // 开始行程
  private async startDrive() {
    const atManager = abilityAccessCtrl.createAtManager();
    const context = this.getUIContext().getHostContext();
    try {
      await atManager.requestPermissionsFromUser(context, [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ]);
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '权限申请失败，请重试' });
      return;
    }

    this.currentDistance = 0;
    this.lastLocation = null;
    this.startTime = Date.now();
    this.totalPausedTime = 0; // 重置暂停累计
    this.segments = [[this.startTime, 0]]; // 第一段开始，结束时间待定
    this.segDistances = [];
    this.segmentStartDistance = 0;
    this.driveStatus = 1; // 行驶中
    this.debugLocation = '正在获取定位...';
    this.debugCoord = '';

    const request: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: 1,
      distanceInterval: 0,
      maxAccuracy: 0
    };

    const self = this;
    const callback: Callback<geoLocationManager.Location> = (location: geoLocationManager.Location): void => {
      self.debugLocation = `定位精度 ${location.accuracy.toFixed(0)} 米 · ${self.formatAccuracy(location.accuracy)}`;
      self.debugCoord = `${location.latitude.toFixed(6)}, ${location.longitude.toFixed(6)}`;
      if (location.accuracy > 100) {
        return;
      }
      if (self.lastLocation) {
        const dist: number = DistanceUtil.calculateDistance(
          self.lastLocation.latitude,
          self.lastLocation.longitude,
          location.latitude,
          location.longitude
        );
        if (dist > 0.001) {
          self.currentDistance = Math.round((self.currentDistance + dist) * 1000) / 1000;
          self.saveDriveState();
        }
      }
      self.lastLocation = location;
    };
    this.locationCallback = callback;
    try {
      geoLocationManager.on('locationChange', request, callback);
    } catch (err) {
      this.driveStatus = 0;
      this.getUIContext().getPromptAction().showToast({ message: '需要位置权限才能记录里程，请在设置中开启' });
    }

    this.startBackgroundRunning();
  }

  // 暂停行程：关GPS、计时暂停
  private pauseDrive() {
    if (this.locationCallback) {
      geoLocationManager.off('locationChange', this.locationCallback);
      this.locationCallback = null;
    }
    this.pauseStartTime = Date.now();
    // 闭合当前行驶段
    if (this.segments.length > 0) {
      this.segments[this.segments.length - 1][1] = this.pauseStartTime;
    }
    // 记录这段里程
    this.segDistances.push(Math.round((this.currentDistance - this.segmentStartDistance) * 1000) / 1000);
    this.driveStatus = 2; // 已暂停
    this.debugLocation = '已暂停，点击继续恢复计程';
    this.getUIContext().getPromptAction().showToast({ message: '行程已暂停' });
    this.saveDriveState();
  }

  // 继续行程：重新开GPS、恢复累计
  private resumeDrive() {
    // 累计这次暂停的时长
    this.totalPausedTime += Date.now() - this.pauseStartTime;
    // 新开一段行驶
    this.segments.push([Date.now(), 0]);
    this.segmentStartDistance = this.currentDistance; // 记录新一段的里程起点
    // 清空上一个点，避免暂停前后位置漂移误算里程
    this.lastLocation = null;
    this.debugLocation = '正在恢复定位...';

    const request: geoLocationManager.LocationRequest = {
      priority: geoLocationManager.LocationRequestPriority.ACCURACY,
      scenario: geoLocationManager.LocationRequestScenario.NAVIGATION,
      timeInterval: 1,
      distanceInterval: 0,
      maxAccuracy: 0
    };

    const self = this;
    const callback: Callback<geoLocationManager.Location> = (location: geoLocationManager.Location): void => {
      self.debugLocation = `定位精度 ${location.accuracy.toFixed(0)} 米 · ${self.formatAccuracy(location.accuracy)}`;
      self.debugCoord = `${location.latitude.toFixed(6)}, ${location.longitude.toFixed(6)}`;
      if (location.accuracy > 100) {
        return;
      }
      if (self.lastLocation) {
        const dist: number = DistanceUtil.calculateDistance(
          self.lastLocation.latitude,
          self.lastLocation.longitude,
          location.latitude,
          location.longitude
        );
        if (dist > 0.001) {
          self.currentDistance = Math.round((self.currentDistance + dist) * 1000) / 1000;
          self.saveDriveState();
        }
      }
      self.lastLocation = location;
    };
    this.locationCallback = callback;
    geoLocationManager.on('locationChange', request, callback);
    this.driveStatus = 1; // 恢复行驶中
    this.getUIContext().getPromptAction().showToast({ message: '继续计程' });
    this.saveDriveState();
  }

  // 结束行程并保存
  private async endDrive() {
    // 如果当前是暂停状态，先把这次暂停时间累计进去
    if (this.driveStatus === 2) {
      this.totalPausedTime += Date.now() - this.pauseStartTime;
    } else if (this.segments.length > 0 && this.segments[this.segments.length - 1][1] === 0) {
      // 行驶中直接结束，闭合最后一段
      this.segments[this.segments.length - 1][1] = Date.now();
      // 记录最后一段里程
      this.segDistances.push(Math.round((this.currentDistance - this.segmentStartDistance) * 1000) / 1000);
    }
    if (this.locationCallback) {
      geoLocationManager.off('locationChange', this.locationCallback);
      this.locationCallback = null;
    }
    this.driveStatus = 0;
    this.stopBackgroundRunning();
    const endTime: number = Date.now();

    if (this.currentDistance > 0.01) {
      const date: Date = new Date();
      const dateStr: string = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
      const record: DriveRecord = {
        startTime: this.startTime,
        endTime: endTime,
        distance: this.currentDistance,
        date: dateStr,
        drivingDuration: endTime - this.startTime - this.totalPausedTime,
        segments: JSON.stringify(this.segments),
        segDistances: JSON.stringify(this.segDistances)
      };
      await DbHelper.addRecord(record);
      this.loadStatistics();
      this.loadHistory();
    }
    this.clearDriveState();
    this.getUIContext().getPromptAction().showToast({ message: '行程已结束' });
  }

  private async loadStatistics() {
    const now: Date = new Date();
    const year: number = now.getFullYear();
    const month: number = now.getMonth();
    const day: number = now.getDate();
    const nowTime: number = now.getTime();

    const dayStart: number = new Date(year, month, day).getTime();
    const weekDay: number = now.getDay() === 0 ? 7 : now.getDay();
    const weekStart: number = new Date(year, month, day - weekDay + 1).getTime();
    const monthStart: number = new Date(year, month, 1).getTime();
    const yearStart: number = new Date(year, 0, 1).getTime();

    this.dayTotal = await DbHelper.getTotalDistance(dayStart, nowTime);
    this.weekTotal = await DbHelper.getTotalDistance(weekStart, nowTime);
    this.monthTotal = await DbHelper.getTotalDistance(monthStart, nowTime);
    this.yearTotal = await DbHelper.getTotalDistance(yearStart, nowTime);
  }

  private async loadHistory() {
    this.recordList = await DbHelper.getAllRecords();
  }

  private formatTime(timestamp: number): string {
    const date: Date = new Date(timestamp);
    return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
  }

  // 行程用时格式化：优先用drivingDuration（实际行驶时间），旧记录没有就用总时间
  private formatDuration(item: DriveRecord): string {
    let ms: number;
    if (item.drivingDuration && item.drivingDuration > 0) {
      ms = item.drivingDuration;
    } else {
      ms = item.endTime - item.startTime;
    }
    return this.formatMs(ms);
  }

  // 毫秒转可读时长
  private formatMs(ms: number): string {
    const minutes: number = Math.round(ms / 60000);
    if (minutes < 1) {
      return '不足1分钟';
    } else if (minutes < 60) {
      return `${minutes}分钟`;
    } else {
      const hours: number = Math.floor(minutes / 60);
      const restMinutes: number = minutes % 60;
      return `${hours}小时${restMinutes}分钟`;
    }
  }

  // 解析分段时间JSON，返回 [[开始,结束],...]
  private parseSegments(item: DriveRecord): number[][] {
    if (!item.segments || item.segments.length === 0) {
      return [];
    }
    try {
      return JSON.parse(item.segments) as number[][];
    } catch (err) {
      return [];
    }
  }

  // 解析分段里程JSON，返回 [0.05, 0.08,...]
  private parseSegDistances(item: DriveRecord): number[] {
    if (!item.segDistances || item.segDistances.length === 0) {
      return [];
    }
    try {
      return JSON.parse(item.segDistances) as number[];
    } catch (err) {
      return [];
    }
  }

  private async confirmRename(id: number) {
    const name: string = this.editName.trim();
    if (name.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '名称不能为空' });
      return;
    }
    await DbHelper.updateRecordName(id, name);
    this.editingId = -1;
    this.recordList = [];
    this.recordList = await DbHelper.getAllRecords();
    this.getUIContext().getPromptAction().showToast({ message: '已重命名' });
  }

  private confirmDelete(id: number) {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除行程',
      message: '确定删除这条行程吗？删除后无法恢复',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '删除', color: '#FF4D4F' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        DbHelper.deleteRecord(id).then(() => {
          this.loadHistory();
          this.loadStatistics();
          this.getUIContext().getPromptAction().showToast({ message: '已删除' });
        });
      }
    });
  }

  build() {
    Stack() {
      if (!this.isAgreedPrivacy) {
        this.privacyPage()
      } else {
        Column() {
          Stack() {
            if (this.currentTab === 0) {
              this.homePage()
            } else if (this.currentTab === 1) {
              this.statisticsPage()
            } else {
              this.historyPage()
            }
          }
          .layoutWeight(1)

          Row() {
            this.tabItem('首页', 0)
            this.tabItem('统计', 1)
            this.tabItem('历史', 2)
          }
          .width('100%')
          .height(56)
          .backgroundColor('#FFFFFF')
          .border({ width: { top: 1 }, color: '#EEEEEE' })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F5F7FA')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F7FA')
  }

  @Builder
  privacyPage() {
    Column() {
      Column() {
        Text('隐私政策')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#007DFF')
          .margin({ top: 24, bottom: 12 })

        Scroll() {
          Column() {
            Text('本应用（姜小白里程计，开发者：侯典宇）非常重视您的个人信息保护。在使用本应用前，请您仔细阅读以下内容：')
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(22)
              .margin({ bottom: 10 })

            Text('一、信息收集与使用')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
              .margin({ top: 4, bottom: 6 })

            Text('1. 位置信息：当您点击"开始行程"时，本应用会通过GPS定位获取您的位置信息，用于计算并记录您的行车里程。位置信息仅在行程记录功能中使用。')
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(22)
              .margin({ bottom: 8 })

            Text('2. 除位置信息外，本应用不收集您的姓名、电话、通讯录、相册等其他任何个人信息。')
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(22)
              .margin({ bottom: 8 })

            Text('二、信息存储与共享')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
              .margin({ top: 4, bottom: 6 })

            Text('1. 您的行车记录数据仅保存在本机数据库中，不会上传至任何服务器，也不会与任何第三方共享。')
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(22)
              .margin({ bottom: 8 })

            Text('2. 卸载应用后，本机保存的数据将被清除。')
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(22)
              .margin({ bottom: 8 })

            Text('三、权限说明')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
              .margin({ top: 4, bottom: 6 })

            Text('本应用申请定位权限（含后台使用），用于计算行车里程。您可以随时在系统设置中关闭该权限，关闭后行程记录功能将无法使用，但不影响其他功能。')
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(22)
              .margin({ bottom: 8 })

            Text('四、您的权利')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
              .margin({ top: 4, bottom: 6 })

            Text('您可以随时卸载本应用以停止使用；卸载后本机保存的全部记录将被清除。如对隐私政策有任何疑问，请联系开发者：2774671053@qq.com')
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(22)
              .margin({ bottom: 8 })

            Text('本政策自2026年10月3日起生效。')
              .fontSize(13)
              .fontColor('#999999')
              .margin({ top: 4, bottom: 10 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .width('100%')
        .height(360)
        .scrollBar(BarState.Off)

        Row() {
          Button('暂不使用')
            .layoutWeight(1)
            .height(44)
            .fontSize(16)
            .fontColor('#999999')
            .backgroundColor('#F0F0F0')
            .borderRadius(22)
            .onClick(() => {
              this.refusePrivacy();
            })

          Button('同意并继续')
            .layoutWeight(1)
            .height(44)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#007DFF')
            .borderRadius(22)
            .onClick(() => {
              this.agreePrivacy();
            })
        }
        .width('100%')
        .margin({ top: 16, bottom: 24 })
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
      }
      .width('88%')
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F7FA')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  tabItem(title: string, index: number) {
    Column() {
      Text(title)
        .fontSize(16)
        .fontColor(this.currentTab === index ? '#007DFF' : '#999999')
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
    }
    .layoutWeight(1)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.currentTab = index;
      if (index === 1) {
        this.loadStatistics();
      } else if (index === 2) {
        this.loadHistory();
      }
    })
  }

  // 首页：开始/暂停/继续大圆按钮 + 结束行程小按钮
  @Builder
  homePage() {
    Column() {
      Text('姜小白里程计')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#007DFF')
        .margin({ top: 60, bottom: 40 })

      Text(this.currentDistance.toFixed(2))
        .fontSize(80)
        .fontWeight(FontWeight.Bold)
        .fontColor('#007DFF')

      Text('公里')
        .fontSize(18)
        .fontColor('#999999')
        .margin({ bottom: 8 })

      Text(this.debugLocation)
        .fontSize(13)
        .fontColor('#999999')
        .margin({ bottom: 4 })

      Text(this.debugCoord)
        .fontSize(11)
        .fontColor('#BBBBBB')
        .margin({ bottom: 60 })

      // 大圆按钮：根据三态变色变字
      Button(this.driveStatus === 0 ? '开始行程' : (this.driveStatus === 1 ? '暂停' : '继续'))
        .width(180)
        .height(180)
        .borderRadius(90)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .backgroundColor(
          this.driveStatus === 0 ? '#52C41A' :  // 空闲=绿色
          this.driveStatus === 1 ? '#FA8C16' :  // 行驶中=橙色
          '#52C41A'                              // 暂停=绿色
        )
        .onClick(() => {
          if (this.driveStatus === 0) {
            this.startDrive();
          } else if (this.driveStatus === 1) {
            this.pauseDrive();
          } else {
            this.resumeDrive();
          }
        })

      // 行程中（行驶或暂停）显示结束按钮
      if (this.driveStatus !== 0) {
        Button('结束行程')
          .width(120)
          .height(40)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor('#FF4D4F')
          .borderRadius(20)
          .margin({ top: 24 })
          .onClick(() => {
            this.endDrive();
          })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  statisticsPage() {
    Column() {
      Text('里程统计')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#007DFF')
        .margin({ top: 60, bottom: 40 })

      Grid() {
        GridItem() {
          this.statCard('今日', this.dayTotal)
        }
        GridItem() {
          this.statCard('本周', this.weekTotal)
        }
        GridItem() {
          this.statCard('本月', this.monthTotal)
        }
        GridItem() {
          this.statCard('本年', this.yearTotal)
        }
      }
      .columnsTemplate('1fr 1fr')
      .rowsTemplate('1fr 1fr')
      .height(400)
      .padding(20)
      .columnsGap(16)
      .rowsGap(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  statCard(title: string, value: number) {
    Column() {
      Text(title).fontSize(16).fontColor('#666666')
      Text(value.toFixed(2)).fontSize(32).fontWeight(FontWeight.Bold).fontColor('#007DFF').margin({ top: 10 })
      Text('公里').fontSize(13).fontColor('#999999').margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  historyPage() {
    Column() {
      Text('历史行程')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#007DFF')
        .margin({ top: 60, bottom: 20 })

      if (this.recordList.length === 0) {
        Text('暂无行程记录')
          .fontSize(16)
          .fontColor('#999999')
          .margin({ top: 100 })
      } else {
        List() {
          ForEach(this.recordList, (item: DriveRecord) => {
            ListItem() {
              if (item.id === this.editingId) {
                Row() {
                  TextInput({ text: this.editName, placeholder: '输入行程名称' })
                    .layoutWeight(1)
                    .height(40)
                    .fontColor('#333333')
                    .placeholderColor('#999999')
                    .backgroundColor('#F0F0F0')
                    .borderRadius(8)
                    .onChange((value: string) => {
                      this.editName = value;
                    })
                  Button('保存')
                    .height(40)
                    .fontSize(14)
                    .backgroundColor('#007DFF')
                    .onClick(() => {
                      this.confirmRename(item.id!);
                    })
                  Button('取消')
                    .height(40)
                    .fontSize(14)
                    .fontColor('#999999')
                    .backgroundColor('#F0F0F0')
                    .onClick(() => {
                      this.editingId = -1;
                    })
                }
                .width('100%')
                .padding(12)
                .backgroundColor('#FFFFFF')
                .borderRadius(12)
                .margin({ bottom: 12 })
              } else {
                Row() {
                  Column() {
                    Text(item.name || item.date)
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#333333')

                    // 分段时间显示：如果有分段记录就多行，没有就显示单行
                    if (this.parseSegments(item).length > 1) {
                      // 有多段：逐行显示每一段
                      ForEach(this.parseSegments(item), (seg: number[], idx: number) => {
                        Row() {
                          Text(`${this.formatTime(seg[0])} - ${this.formatTime(seg[1])} · ${this.formatMs(seg[1] - seg[0])}`)
                            .fontSize(12)
                            .fontColor('#BBBBBB')
                          // 每段里程
                          Text(`${this.parseSegDistances(item)[idx]?.toFixed(2) ?? '0.00'} km`)
                            .fontSize(12)
                            .fontColor('#999999')
                            .margin({ left: 8 })
                        }
                        .margin({ top: 2 })
                      }, (seg: number[], idx: number) => `${seg[0]}-${seg[1]}`)
                      Text(`总行驶：${this.formatDuration(item)} · ${item.distance.toFixed(2)} km`)
                        .fontSize(12)
                        .fontColor('#007DFF')
                        .fontWeight(FontWeight.Medium)
                        .margin({ top: 4 })
                    } else {
                      // 单段或旧记录：显示一行
                      Text(`${this.formatTime(item.startTime)} - ${this.formatTime(item.endTime)} · ${this.formatDuration(item)}`)
                        .fontSize(12)
                        .fontColor('#BBBBBB')
                        .margin({ top: 4 })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Column() {
                    Text(`${item.distance.toFixed(2)} km`)
                      .fontSize(18)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#007DFF')
                    Row() {
                      Text('重命名')
                        .fontSize(12)
                        .fontColor('#007DFF')
                        .onClick(() => {
                          this.editingId = item.id!;
                          this.editName = item.name || '';
                        })
                      Text('  |  ')
                        .fontSize(12)
                        .fontColor('#DDDDDD')
                      Text('删除')
                        .fontSize(12)
                        .fontColor('#FF4D4F')
                        .onClick(() => {
                          this.confirmDelete(item.id!);
                        })
                    }
                    .margin({ top: 6 })
                  }
                  .alignItems(HorizontalAlign.End)
                }
                .width('100%')
                .padding(16)
                .backgroundColor('#FFFFFF')
                .borderRadius(12)
                .margin({ bottom: 12 })
              }
            }
          }, (item: DriveRecord) => `${item.id}-${item.name || ''}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 20, right: 20 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }
}






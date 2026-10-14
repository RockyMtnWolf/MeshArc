import { MotionTokens } from './MotionTokens';
import { AnimationSettings, DEFAULT_ANIMATION_SETTINGS } from '../services/AnimationPreferences';
import {
  BlurStrategy,
  HdsNavDestination,
  HdsNavDestinationAttribute,
  HdsNavDestinationTitleMode,
  HdsNavigation,
  HdsNavigationAttribute,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  DividerShowType,
  IconStyleMode,
  hdsMaterial
} from '@kit.UIDesignKit';

/**
 * Native settings surface used by the settings half-modal.
 *
 * Navigation owns the two detail pages while bindSheet owns presentation.
 * Keeping those responsibilities separate makes the sheet dismissible without
 * coupling the settings pages to the app's primary HdsNavigation stack.
 */
@Component
export struct NativeSettingsNavigation {
  @Prop glowLevel: number = 3;
  @Prop backgroundImageUri: string = '';
  @Prop profileName: string = '';
  @Prop storageAppDataBytes: number = 0;
  @Prop storageReceivedBytes: number = 0;
  @Prop storageTemporaryBytes: number = 0;
  @Prop storageClearEnabled: boolean = false;
  @Prop backgroundPickerInProgress: boolean = false;
  @Prop backgroundClearEnabled: boolean = false;
  @Prop immersiveColorEnabled: boolean = false;
  @Prop pageName: string = 'background';
  onGlowLevelChange: (level: number) => void = (_level: number) => {};
  onSelectBackground: () => void = () => {};
  onClearBackground: () => void = () => {};
  onImmersiveColorChange: (enabled: boolean) => void = (_enabled: boolean) => {};
  onSelectTransfer: () => void = () => {};
  onClearTemporaryStorage: () => void = () => {};
  onAnimationSettingsChange: (settings: AnimationSettings) => void = (_settings: AnimationSettings) => {};
  onDismiss: () => void = () => {};

  @State hdrEnabled: boolean = false;
  @State floatingTabsEnabled: boolean = false;
  @State materialBrightness: number = 52;
  @State intelligentMaterialIndex: number = 0;
  @Prop initialAnimationDuration: number = DEFAULT_ANIMATION_SETTINGS.duration;
  @Prop initialAnimationAmplitude: number = DEFAULT_ANIMATION_SETTINGS.amplitude;
  @Prop initialAnimationDamping: number = DEFAULT_ANIMATION_SETTINGS.damping;
  @Prop initialAnimationPreset: number = DEFAULT_ANIMATION_SETTINGS.preset;
  @State animationDuration: number = DEFAULT_ANIMATION_SETTINGS.duration;
  @State animationAmplitude: number = DEFAULT_ANIMATION_SETTINGS.amplitude;
  @State animationDamping: number = DEFAULT_ANIMATION_SETTINGS.damping;
  @State animationPreset: number = DEFAULT_ANIMATION_SETTINGS.preset;
  @State previewActive: boolean = false;
  @State materialIndex: number = 3;

  private navPathStack: NavPathStack = new NavPathStack();
  private pageScroller: Scroller = new Scroller();
  private navigationLockUntilMs: number = 0;
  private previewAnimationLockUntilMs: number = 0;

  aboutToAppear(): void {
    this.materialIndex = this.glowLevel >= 0 && this.glowLevel <= 3 ? this.glowLevel : 3;
    this.animationDuration = this.initialAnimationDuration;
    this.animationAmplitude = this.initialAnimationAmplitude;
    this.animationDamping = this.initialAnimationDamping;
    this.animationPreset = this.initialAnimationPreset;
  }

  private materialLevel(): hdsMaterial.MaterialLevel {
    switch (this.materialIndex) {
      case 0: return hdsMaterial.MaterialLevel.EXQUISITE;
      case 1: return hdsMaterial.MaterialLevel.GENTLE;
      case 2: return hdsMaterial.MaterialLevel.SMOOTH;
      default: return hdsMaterial.MaterialLevel.ADAPTIVE;
    }
  }

  private modalTitleBar(title: ResourceStr, opaqueBackground: boolean = false): HdsNavigationTitleBarOptions {
    const options: HdsNavigationTitleBarOptions = {
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: title },
        menu: {
          value: [{
            content: {
              label: $r('app.string.native_settings_close'),
              icon: $r('sys.symbol.xmark'),
              isEnabled: true,
              type: IconStyleMode.SMALL,
              action: () => this.onDismiss()
            }
          }]
        },
        divider: { showType: DividerShowType.OFF }
      },
      style: {
        blurStrategy: BlurStrategy.DISABLE,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: this.materialLevel()
        }
      }
    };
    if (opaqueBackground) {
      options.style = {
        blurStrategy: BlurStrategy.DISABLE,
        scrollEffectOpts: { enableScrollEffect: false },
        originalStyle: { backgroundStyle: { backgroundColor: $r('sys.color.background_secondary') } },
        scrollEffectStyle: { backgroundStyle: { backgroundColor: $r('sys.color.background_secondary') } }
      };
    }
    return options;
  }

  private materialLabel(): ResourceStr {
    switch (this.materialIndex) {
      case 0: return $r('app.string.native_settings_material_exquisite');
      case 1: return $r('app.string.native_settings_material_gentle');
      case 2: return $r('app.string.native_settings_material_smooth');
      default: return $r('app.string.native_settings_material_adaptive');
    }
  }

  private selectMaterial(index: number): void {
    if (index < 0 || index > 3) {
      return;
    }
    this.materialIndex = index;
    this.onGlowLevelChange(index);
  }

  private pushPage(name: string): void {
    const now: number = Date.now();
    if (name.length === 0 || now < this.navigationLockUntilMs) {
      return;
    }
    // Navigation already owns the page transition. Wrapping pushPath in a
    // second animateTo callback can defer several taps and replay them later.
    this.navigationLockUntilMs = now + MotionTokens.PAGE;
    this.navPathStack.pushPath({ name: name }, true);
  }

  private popPage(): void {
    const now: number = Date.now();
    if (now < this.navigationLockUntilMs) {
      return;
    }
    this.navigationLockUntilMs = now + MotionTokens.PAGE;
    this.navPathStack.pop();
  }

  private togglePreview(settings: AnimationSettings = this.currentAnimationSettings()): void {
    const duration: number = this.animationDurationMs(settings.duration);
    const now: number = Date.now();
    if (now < this.previewAnimationLockUntilMs) {
      return;
    }
    // Do not enqueue another animateTo while the previous preview motion is
    // still running. Queued callbacks are perceived as delayed menu opens.
    this.previewAnimationLockUntilMs = now + duration + MotionTokens.FAST;
    this.getUIContext().animateTo({
      duration: duration,
      curve: MotionTokens.curveFor(settings)
    }, () => {
      this.previewActive = !this.previewActive;
    });
  }

  private animationDurationMs(duration: number = this.animationDuration): number {
    return MotionTokens.durationFor(400, duration);
  }

  private storageMegabytes(bytes: number): string {
    const megabytes: number = Math.max(0, bytes) / (1024 * 1024);
    return `${megabytes.toFixed(1)} MB`;
  }

  private storageTotalBytes(): number {
    return Math.max(0, this.storageAppDataBytes) + Math.max(0, this.storageReceivedBytes) +
      Math.max(0, this.storageTemporaryBytes);
  }

  private storageTotalLabel(): string {
    return `${(this.storageTotalBytes() / (1024 * 1024)).toFixed(1)} MB`;
  }

  private currentAnimationSettings(): AnimationSettings {
    return {
      preset: this.animationPreset,
      duration: this.animationDuration,
      amplitude: this.animationAmplitude,
      damping: this.animationDamping
    };
  }

  private previewTravel(): number {
    return 38 * MotionTokens.amplitudeScale(this.animationAmplitude);
  }

  private previewPrimaryX(): number {
    return this.previewActive ? this.previewTravel() : -this.previewTravel();
  }

  private previewSecondaryX(): number {
    return this.previewActive ? -this.previewTravel() : this.previewTravel();
  }

  private previewPrimaryRotation(): number {
    const angle: number = 1.5 + this.animationAmplitude * 0.025;
    return this.previewActive ? angle : -angle;
  }

  private previewSecondaryRotation(): number {
    return -this.previewPrimaryRotation();
  }

  private previewIndicatorX(): number {
    return this.previewActive ? 22 : -22;
  }

  private applyAnimationSettingsLocally(settings: AnimationSettings): void {
    this.animationPreset = settings.preset;
    this.animationDuration = settings.duration;
    this.animationAmplitude = settings.amplitude;
    this.animationDamping = settings.damping;
  }

  private updateAnimationSettings(settings: AnimationSettings, mode: SliderChangeMode): void {
    this.applyAnimationSettingsLocally(settings);
    this.onAnimationSettingsChange(settings);
    if (mode === SliderChangeMode.End) {
      this.togglePreview(settings);
    }
  }

  private applyPreset(index: number): void {
    let duration: number = 60;
    let amplitude: number = 56;
    let damping: number = 64;
    if (index === 0) {
      duration = 28;
      amplitude = 32;
      damping = 82;
    } else if (index === 2) {
      duration = 78;
      amplitude = 72;
      damping = 42;
    }

    const settings: AnimationSettings = {
      preset: index,
      duration: duration,
      amplitude: amplitude,
      damping: damping
    };
    const animationDurationMs: number = this.animationDurationMs(duration);
    const now: number = Date.now();
    if (now < this.previewAnimationLockUntilMs) {
      this.applyAnimationSettingsLocally(settings);
      this.onAnimationSettingsChange(settings);
      return;
    }
    this.previewAnimationLockUntilMs = now + animationDurationMs + MotionTokens.FAST;
    this.getUIContext().animateTo({
      duration: animationDurationMs,
      curve: MotionTokens.curveFor(settings)
    }, () => {
      this.applyAnimationSettingsLocally(settings);
      this.onAnimationSettingsChange(settings);
      this.previewActive = !this.previewActive;
    });
  }

  @Builder
  private IconButton(icon: Resource, label: Resource, action: () => void,
    rotation: number = 0): void {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([$r('app.color.emphasize')])
        .rotate({ angle: rotation })
    }
      .width(46)
      .height(46)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: $r('sys.color.comp_divider'), radius: 23 })
      .accessibilityText(label)
      .onClick(action)
  }

  @Builder
  private TopBar(title: ResourceStr, showBack: boolean): void {
    Row({ space: 8 }) {
      if (showBack) {
        this.IconButton($r('sys.symbol.chevron_right'), $r('app.string.native_settings_back'),
          () => this.popPage(), 180)
      } else {
        Blank().width(46).height(46)
      }
      Text(title)
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      this.IconButton($r('sys.symbol.xmark'), $r('app.string.native_settings_close'),
        () => this.onDismiss())
    }
      .width('100%')
      .padding({ left: 18, right: 18, top: 12, bottom: 8 })
  }

  @Builder
  private SectionTitle(title: ResourceStr): void {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_secondary'))
      .width('100%')
      .padding({ left: 18, bottom: 8 })
  }

  @Builder
  private SettingsRow(icon: Resource, title: ResourceStr, subtitle: ResourceStr,
    trailing: ResourceStr, action: () => void, rowId: string): void {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        SymbolGlyph(icon)
          .fontSize(22)
          .fontColor([$r('app.color.emphasize')])
          .width(26)
        Column({ space: 3 }) {
          Text(title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (subtitle !== '') {
            Text(subtitle)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        if (trailing !== '') {
          Text(trailing)
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(17)
          .fontColor([$r('app.color.emphasize')])
      }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 14 })
    }
      .width('100%')
      .height(72)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .id(rowId)
      .onClick(action)
  }

  @Builder
  private TransferSpaceRow(icon: Resource, title: ResourceStr, action: () => void,
    rowId: string): void {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 18 }) {
        Image(icon)
          .width(48)
          .height(48)
          .objectFit(ImageFit.Contain)
        Text(title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(22)
          .fontColor([$r('app.color.emphasize')])
      }
        .width('100%')
        .height('100%')
        .padding({ left: 18, right: 18 })
    }
      .width('100%')
      .height(88)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .id(rowId)
      .onClick(action)
  }

  @Builder
  private ProfileHero(): void {
    Column({ space: 8 }) {
      Image($r('app.media.app_icon'))
        .width(84)
        .height(84)
        .borderRadius(42)
        .objectFit(ImageFit.Cover)
        .border({ width: 2, color: $r('sys.color.comp_background_primary'), radius: 42 })
        .shadow({ radius: 14, color: '#33000000', offsetY: 5 })
      Text(this.profileName.length > 0 ? this.profileName : $r('app.string.native_settings_profile_default'))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 10 }) {
          Text('✦')
            .fontSize(25)
            .fontColor($r('app.color.emphasize'))
          Text($r('app.string.native_settings_vip'))
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
          Text($r('app.string.native_settings_vip_action'))
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([$r('sys.color.icon_secondary')])
        }
          .width('100%')
          .height('100%')
          .padding({ left: 18, right: 16 })
      }
        .width('100%')
        .height(76)
        .padding(0)
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(24)
        .id('native-settings-vip')
        .onClick(() => {})
    }
      .width('100%')
      .padding({ left: 18, right: 18, top: 8, bottom: 8 })
      .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private SettingsHome(): void {
    Scroll() {
      Column({ space: 14 }) {
        this.ProfileHero()

        this.SectionTitle($r('app.string.native_settings_transfer_section'))
        Column({ space: 2 }) {
          this.TransferSpaceRow($r('app.media.native_transfer_entry'),
            $r('app.string.native_settings_transfer'), () => this.onSelectTransfer(),
            'native-settings-transfer')
          this.TransferSpaceRow($r('app.media.native_storage_entry'),
            $r('app.string.native_settings_storage'), () => this.pushPage('storage'),
            'native-settings-storage')
        }
          .width('calc(100% - 36vp)')
          .margin({ left: 18, right: 18 })
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(28)
          .clip(true)

        this.SectionTitle($r('app.string.native_settings_appearance_section'))
        Column({ space: 0 }) {
          this.SettingsRow($r('sys.symbol.doc'), $r('app.string.native_settings_theme'),
            '', '', () => {}, 'native-settings-theme')
          Divider().color($r('sys.color.comp_divider')).margin({ left: 54, right: 16 })
          this.SettingsRow($r('sys.symbol.eye'), $r('app.string.native_settings_color_mode'),
            '', $r('app.string.native_settings_system_follow'), () => {},
            'native-settings-color-mode')
          Divider().color($r('sys.color.comp_divider')).margin({ left: 54, right: 16 })
          this.SettingsRow($r('sys.symbol.picture'),
            $r('app.string.native_settings_background_material'), '', '',
            () => this.pushPage('background'), 'native-settings-background-material')
          Divider().color($r('sys.color.comp_divider')).margin({ left: 54, right: 16 })
          this.SettingsRow($r('sys.symbol.arrow_clockwise'),
            $r('app.string.native_settings_animation'), '', '',
            () => this.pushPage('animation'), 'native-settings-animation')
        }
          .width('calc(100% - 36vp)')
          .margin({ left: 18, right: 18 })
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(22)
          .clip(true)

        this.SectionTitle($r('app.string.native_settings_help_section'))
        Column({ space: 0 }) {
          this.SettingsRow($r('sys.symbol.doc'), $r('app.string.native_settings_usage'),
            '', '', () => {}, 'native-settings-usage')
        }
          .width('calc(100% - 36vp)')
          .margin({ left: 18, right: 18, bottom: 24 })
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(22)
          .clip(true)
      }
        .width('100%')
        .padding({ top: 4, bottom: 16 })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Auto)
      .nestedScroll({
        scrollForward: NestedScrollMode.PARENT_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST
      })
  }

  @Builder
  private PreviewCard(): void {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Stack({ alignContent: Alignment.Center }) {
        Column({ space: 12 }) {
          Row({ space: 6 }) {
            Circle().width(7).height(7).fill($r('app.color.emphasize'))
            Circle().width(7).height(7).fill($r('sys.color.comp_divider'))
            Circle().width(7).height(7).fill($r('sys.color.comp_divider'))
          }
            .width('100%')
            .padding({ left: 16 })

          Stack({ alignContent: Alignment.Center }) {
            Column({ space: 10 }) {
              Row()
                .width(52)
                .height(8)
                .borderRadius(4)
                .backgroundColor($r('app.color.emphasize'))
              Row()
                .width(74)
                .height(7)
                .borderRadius(4)
                .backgroundColor($r('sys.color.comp_divider'))
              Row({ space: 7 }) {
                Circle().width(20).height(20).fill('#2F8F70')
                Row()
                  .width(50)
                  .height(28)
                  .borderRadius(8)
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
              }
            }
              .width(122)
              .height(116)
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor($r('sys.color.comp_background_primary'))
              .borderRadius(16)
              .shadow({ radius: 16, color: '#24000000', offsetY: 6 })
              .rotate({ angle: this.previewPrimaryRotation() })
              .translate({ x: this.previewPrimaryX() })

            Column({ space: 10 }) {
              Row({ space: 6 }) {
                Circle().width(24).height(24).fill('#D8862C')
                Column({ space: 4 }) {
                  Row()
                    .width(48)
                    .height(7)
                    .borderRadius(4)
                    .backgroundColor($r('app.color.emphasize'))
                  Row()
                    .width(34)
                    .height(6)
                    .borderRadius(3)
                    .backgroundColor($r('sys.color.comp_divider'))
                }
              }
              Row()
                .width(82)
                .height(34)
                .borderRadius(9)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
              Row()
                .width(64)
                .height(7)
                .borderRadius(4)
                .backgroundColor($r('sys.color.comp_divider'))
            }
              .width(122)
              .height(116)
              .padding(16)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor($r('sys.color.comp_background_primary'))
              .borderRadius(16)
              .shadow({ radius: 16, color: '#24000000', offsetY: 6 })
              .rotate({ angle: this.previewSecondaryRotation() })
              .translate({ x: this.previewSecondaryX() })
          }
            .width('100%')
            .layoutWeight(1)

          Stack({ alignContent: Alignment.Center }) {
            Row()
              .width(64)
              .height(5)
              .borderRadius(3)
              .backgroundColor($r('sys.color.comp_divider'))
            Circle()
              .width(11)
              .height(11)
              .fill($r('app.color.emphasize'))
              .translate({ x: this.previewIndicatorX() })
          }
            .width('100%')
            .height(14)
        }
          .width('86%')
          .height(198)
          .padding({ top: 14, bottom: 12 })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius(20)
      }
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
        .borderRadius(24)
        .clip(true)
    }
      .width('100%')
      .height(240)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: $r('sys.color.comp_divider'), radius: 24 })
      .id('native-settings-preview')
      .onClick(() => this.togglePreview())
  }

  @Builder
  private ToggleRow(title: ResourceStr, description: ResourceStr, isOn: boolean,
    onChange: (value: boolean) => void): void {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Text(description)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .maxLines(2)
      }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor($r('app.color.emphasize'))
        .onChange(onChange)
    }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  @Builder
  private SliderRow(title: ResourceStr, value: number,
    onChange: (value: number, mode: SliderChangeMode) => void): void {
    Row({ space: 12 }) {
      Text(title)
        .fontSize(15)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Slider({ value: value, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
        .layoutWeight(1.15)
        .onChange(onChange)
    }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  private BackgroundPage(): void {
    Column() {
      Scroll(this.pageScroller) {
        Column({ space: 14 }) {
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.picture'))
                .fontSize(22)
                .fontColor([$r('app.color.emphasize')])
              Text($r('app.string.native_settings_choose_background'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(17)
                .fontColor([$r('sys.color.icon_secondary')])
            }
              .width('100%')
              .height('100%')
              .padding({ left: 16, right: 14 })
          }
            .width('100%')
            .height(66)
            .padding(0)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(20)
            .enabled(!this.backgroundPickerInProgress)
            .id('native-settings-choose-background')
            .onClick(() => this.onSelectBackground())

          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(21)
                .fontColor([$r('app.color.status_error')])
              Text($r('app.string.native_settings_clear_background'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.status_error'))
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
            }
              .width('100%')
              .height('100%')
              .padding({ left: 16, right: 14 })
          }
            .width('100%')
            .height(58)
            .padding(0)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(20)
            .enabled(this.backgroundClearEnabled)
            .opacity(this.backgroundClearEnabled ? 1 : 0.42)
            .id('native-settings-clear-background')
            .onClick(() => this.onClearBackground())

          Column({ space: 0 }) {
            this.ToggleRow($r('app.string.native_settings_immersive_color'),
              $r('app.string.native_settings_immersive_color_desc'), this.immersiveColorEnabled,
              (value: boolean) => this.onImmersiveColorChange(value))
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(20)
            .clip(true)

          Column({ space: 0 }) {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text($r('app.string.native_settings_material'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
              }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              Select([
                { value: $r('app.string.native_settings_material_exquisite') },
                { value: $r('app.string.native_settings_material_gentle') },
                { value: $r('app.string.native_settings_material_smooth') },
                { value: $r('app.string.native_settings_material_adaptive') }
              ])
                .selected(this.materialIndex)
                .value(this.materialLabel())
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .controlSize(ControlSize.SMALL)
                .constraintSize({ minWidth: 104, maxWidth: 128 })
                .onSelect((index: number) => this.selectMaterial(index))
            }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
            this.SliderRow($r('app.string.native_settings_brightness'), this.materialBrightness,
              (value: number, _mode: SliderChangeMode) => this.materialBrightness = value)
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text($r('app.string.native_settings_intelligent_material'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                Text($r('app.string.native_settings_intelligent_material_desc'))
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
                  .maxLines(2)
              }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              Select([{ value: $r('app.string.native_settings_material_adaptive') },
                { value: $r('app.string.native_settings_material_smooth') }])
                .selected(this.intelligentMaterialIndex)
                .value(this.intelligentMaterialIndex === 0 ?
                  $r('app.string.native_settings_material_adaptive') :
                  $r('app.string.native_settings_material_smooth'))
                .font({ size: 14 })
                .optionFont({ size: 14 })
                .controlSize(ControlSize.SMALL)
                .constraintSize({ minWidth: 104, maxWidth: 128 })
                .onSelect((index: number) => this.intelligentMaterialIndex = index)
            }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(20)
            .clip(true)

        }
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 28 })
      }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Auto)
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
    }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private AnimationPage(): void {
    Column() {
      Scroll(this.pageScroller) {
        Column({ space: 14 }) {
          this.PreviewCard()
          Column({ space: 0 }) {
            this.SliderRow($r('app.string.native_settings_animation_duration'),
              this.animationDuration, (value: number, mode: SliderChangeMode) =>
                this.updateAnimationSettings({
                  preset: this.animationPreset,
                  duration: value,
                  amplitude: this.animationAmplitude,
                  damping: this.animationDamping
                }, mode))
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
            this.SliderRow($r('app.string.native_settings_animation_amplitude'),
              this.animationAmplitude, (value: number, mode: SliderChangeMode) =>
                this.updateAnimationSettings({
                  preset: this.animationPreset,
                  duration: this.animationDuration,
                  amplitude: value,
                  damping: this.animationDamping
                }, mode))
            Divider().color($r('sys.color.comp_divider')).margin({ left: 16, right: 16 })
            this.SliderRow($r('app.string.native_settings_animation_damping'),
              this.animationDamping, (value: number, mode: SliderChangeMode) =>
                this.updateAnimationSettings({
                  preset: this.animationPreset,
                  duration: this.animationDuration,
                  amplitude: this.animationAmplitude,
                  damping: value
                }, mode))
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(20)
            .clip(true)

          Row({ space: 10 }) {
            this.PresetButton(0, $r('app.string.native_settings_preset_efficiency'))
            this.PresetButton(1, $r('app.string.native_settings_preset_default'))
            this.PresetButton(2, $r('app.string.native_settings_preset_lively'))
          }
            .width('100%')
            .height(54)
            .justifyContent(FlexAlign.SpaceBetween)
        }
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 28 })
      }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Auto)
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
    }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private StorageSummaryRow(color: ResourceColor, title: ResourceStr, bytes: number,
    rowId: string): void {
    Row({ space: 14 }) {
      Circle()
        .width(14)
        .height(14)
        .fill(color)
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.storageMegabytes(bytes))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
    }
      .width('100%')
      .height(74)
      .padding({ left: 22, right: 22 })
      .id(rowId)
  }

  @Builder
  private StoragePage(): void {
    Column() {
      Scroll(this.pageScroller) {
        Column({ space: 22 }) {
          Stack({ alignContent: Alignment.Center }) {
            Row()
              .width(278)
              .height(278)
              .borderRadius(139)
              .border({ width: 24, color: '#21005D', radius: 139 })
              .shadow({ radius: 22, color: '#35000000', offsetY: 8 })
            Column({ space: 8 }) {
              Text(this.storageTotalLabel())
                .fontSize(46)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
              Text($r('app.string.native_settings_storage_total'))
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary'))
            }
          }
            .width('100%')
            .height(328)

          Column({ space: 0 }) {
            this.StorageSummaryRow($r('app.color.emphasize'),
              $r('app.string.native_settings_storage_app_data'), this.storageAppDataBytes,
              'native-settings-storage-app-data')
            Divider().color($r('sys.color.comp_divider')).margin({ left: 22, right: 22 })
            this.StorageSummaryRow($r('app.color.emphasize'),
              $r('app.string.native_settings_storage_received'), this.storageReceivedBytes,
              'native-settings-storage-received')
            Divider().color($r('sys.color.comp_divider')).margin({ left: 22, right: 22 })
            this.StorageSummaryRow('#FFB43B',
              $r('app.string.native_settings_storage_temporary'), this.storageTemporaryBytes,
              'native-settings-storage-temporary')
          }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(26)
            .clip(true)

          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Row({ space: 12 }) {
              Text($r('app.string.native_settings_storage_clear'))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
              Text($r('app.string.native_settings_storage_clear_action'))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.emphasize'))
            }
              .width('100%')
              .height('100%')
              .padding({ left: 22, right: 22 })
          }
            .width('100%')
            .height(78)
            .padding(0)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius(26)
            .enabled(this.storageClearEnabled)
            .id('native-settings-storage-clear')
            .onClick(() => this.onClearTemporaryStorage())
        }
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 28 })
      }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Auto)
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
  }

  @Builder
  private PresetButton(index: number, title: ResourceStr): void {
    Button({ type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true }) {
      Text(title)
        .fontSize(15)
        .fontColor(this.animationPreset === index ? $r('app.color.emphasize') :
          $r('sys.color.font_primary'))
    }
      .layoutWeight(1)
      .height(54)
      .padding(0)
      .backgroundColor(this.animationPreset === index ? '#E7E1FF' :
        $r('sys.color.comp_background_primary'))
      .onClick(() => this.applyPreset(index))
  }

  @Builder
  private PageMap(name: string): void {
    if (name === 'background') {
      HdsNavDestination() {
        this.BackgroundPage()
      }
        .titleMode(HdsNavDestinationTitleMode.MODAL)
        .titleBar(this.modalTitleBar($r('app.string.native_settings_background_material'), true))
        .hideBackButton(true)
        .bindToScrollable([this.pageScroller])
        .backgroundColor($r('sys.color.background_secondary'))
    } else if (name === 'animation') {
      HdsNavDestination() {
        this.AnimationPage()
      }
        .titleMode(HdsNavDestinationTitleMode.MODAL)
        .titleBar(this.modalTitleBar($r('app.string.native_settings_animation'), true))
        .hideBackButton(true)
        .bindToScrollable([this.pageScroller])
        .backgroundColor($r('sys.color.background_secondary'))
    } else if (name === 'storage') {
      HdsNavDestination() {
        this.StoragePage()
      }
        .titleMode(HdsNavDestinationTitleMode.MODAL)
        .titleBar(this.modalTitleBar($r('app.string.native_settings_storage')))
        .hideBackButton(false)
        .bindToScrollable([this.pageScroller])
        .backgroundColor(Color.Transparent)
    }
  }

  build() {
    HdsNavigation() {
      if (this.pageName === 'animation') {
        this.AnimationPage()
      } else {
        this.BackgroundPage()
      }
    }
      .titleMode(HdsNavigationTitleMode.MODAL)
      .mode(NavigationMode.Stack)
      .titleBar(this.modalTitleBar(this.pageName === 'animation' ?
        $r('app.string.native_settings_animation') :
        $r('app.string.native_settings_background_material'), true))
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
      .id(this.pageName === 'animation' ?
        'native-animation-settings' : 'native-background-material-settings')
  }
}

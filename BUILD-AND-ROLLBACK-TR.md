# Henge (KeremOS iPad Air M3 Edition) — Derleme, İmzalanma ve Geri Dönüş Rehberi

Bu belge, **iPad Air M3 (8 GB RAM, iPadOS 27.0, Magic Keyboard)** ve **Windows PC + Sideloadly** kurulumu için kaynak koddan yapılan değişikliklerin nasıl derleneceğini, imzalanacağını ve gerektiğinde nasıl geri alınacağını (rollback) açıklar.

---

## 1. Windows ve macOS Sınırları (Önemli Doğrulama Notu)

- **Windows üzerinde yapılabilenler:**
  - Kaynak kod geliştirme (`C11` emülatör motoru, `Objective-C` Metal köprüsü, `SwiftUI` arayüz ve JIT mantığı).
  - İmzalamaya hazır `.ipa` dosyasını **Sideloadly** ile kendi Apple hesabınız üzerinden (`get-task-allow` açık şekilde) iPad Air M3'e yükleme.
  - `idevicepair` / `jitterbugpair` ile eşleştirme dosyası (`.mobiledevicepairing` / `.plist`) üretme.
- **macOS + Xcode gerektiren adımlar:**
  - Apple'ın `iphoneos` SDK'sı, `Metal`, `IOSurface`, `AudioToolbox`, `SwiftUI` ve `AppExtension` (`HengeJITHelper.appex`) hedeflerinin derlenmesi yalnızca **macOS + Xcode** (veya **GitHub Actions `macos-15` runner**) üzerinde yapılabilir.
  - Windows üzerinde yerel bir `iphoneos` SDK ve `xcodebuild` bulunmadığından, bu depodaki kaynak kod değişiklikleri Windows'ta doğrudan `.ipa` ikili dosyasına derlenmemiştir; bunun yerine tekrar üretilebilir derleme betikleri (`ios/scripts/fetch_deps.sh`, `ios/scripts/package_ipa.sh`) ve otomatik **GitHub Actions iş akışı** (`.github/workflows/build-ipa.yml`) hazırlanmıştır.

---

## 2. Kaynak Koddan Tekrar Üretilebilir Derleme

### Yöntem A: GitHub Actions ile Bulutta Derleme (Mac Bilgisayarınız Yoksa Önerilen)

1. Bu depoyu kendi GitHub hesabınıza (`private` veya `public` repo olarak) pushlayın:
   ```bash
   git push https://github.com/<kullanici-adiniz>/Henge-KeremOS.git feat/keremos-m3-v1:main
   ```
2. GitHub deponuzda **Actions** sekmesine girin ve **"Build Henge IPA (iPad Air M3 / KeremOS)"** iş akışını çalıştırın (`Run workflow`).
3. İş akışı tamamlandığında **Artifacts** bölümünden `Henge-KeremOS-M3-ipa.zip` dosyasını indirin; içinden imzalamaya hazır `Henge.ipa` çıkacaktır.

### Yöntem B: macOS + Xcode Üzerinde Yerel Derleme

macOS yüklü bir bilgisayarda (Xcode ve Homebrew kurulu):

```zsh
brew install xcodegen cmake
cd Henge-KeremOS

# 1. Bağımlılıkları hazırla (Husk varsa oradan kopyalar, yoksa resmi Henge v0.1 IPA'dan StikJIT.framework'ü çıkarır ve yardımcı kütüphaneleri derler)
./ios/scripts/fetch_deps.sh

# 2. Kaynak kod ve ekran yönlendirme doğrulamasını çalıştır
./ios/scripts/check_display.sh

# 3. İmzalamaya hazır Henge.ipa paketini oluştur (~/Desktop/Henge.ipa)
./ios/scripts/package_ipa.sh
```

> **Tam Ağ (`libslirp`) ve Cihaz İçi Eşleştirme (`libhusk_rppairing`) Notu:**
> `fetch_deps.sh`, ortamda `$HUSK` (`$HOME/Documents/Coding/Husk`) dizini varsa tam `libslirp.a` ve `libhusk_rppairing.a` kütüphanelerini oradan alır. `$HUSK` yoksa derlemenin kırılmaması için resmi v0.1 IPA'dan `StikJIT.framework`'ü çıkarır ve temiz C yedeklerini (fallback) derler. İçe aktarılan eşleştirme dosyası (`pairingFile.plist`) ile çalışan yerleşik StikJIT (`HengeJITHelper.appex`) her iki modda da tam çalışır.

---

## 3. Windows'ta Sideloadly ile İmzalanma ve Kurulum

1. **Sideloadly** uygulamasını Windows'ta açın ve iPad Air M3 cihazınızı USB ile bağlayın.
2. `Henge.ipa` dosyasını Sideloadly'ye sürükleyin.
3. Apple ID'nizi girin (Normal ücretsiz veya geliştirici Apple hesabı; Sideloadly varsayılan olarak geliştirme imzası atar ve **`get-task-allow` iznini korur**).
   - **Uyarı:** ESign veya dağıtım sertifikasıyla `get-task-allow` olmadan imzalarsanız `increased-memory-limit` korunur ancak iPadOS 27 TXM altında JIT hata ayıklayıcı (`HengeJITHelper` / `StikDebug`) sürece **bağlanamaz** (`JIT Ön Kontrol Listesi` bunu artık açıkça "İmza (get-task-allow): Eksik" olarak gösterir).
4. Uygulamayı mevcut Henge'in üzerine (`same Bundle ID`) yüklerseniz `Documents/Machines/` içindeki sanal Mac'leriniz, `Documents/Restore.ipsw` dosyanız ve `UserDefaults` ayarlarınız **korunur**.

---

## 4. iPad Air M3 (8 GB) Üzerinde Doğrulama Adımları

1. **JIT Ön Kontrol Listesi (`Ayarlar` veya `Kurulum` ekranı):**
   - `İmza (get-task-allow)` -> **Hazır**
   - `Yerleşik StikJIT Uzantısı` -> **Hazır**
   - `Eşleştirme Dosyası` -> **İçe Aktarıldı**
   - `LocalDevVPN / Bağlantı` -> LocalDevVPN açıkken **Kontrol Et**'e basın -> **Ulaşılabilir**
   - `JIT Kod Çalıştırma Testi` -> `henge_jit_selftest() == 42` doğrulandığında **Doğrulandı (Canlı)** yazar.
2. **RAM Seçimi ve 4 Boyutlu Bellek Özeti (`Yeni Sanal Mac` veya `Mac Ayarları`):**
   - Sideloadly imzasında (`increased-memory-limit` kırpılmışken) uygulama otomatik olarak **3 GB (Önerilen: 3 GB)** değerini seçer.
   - 4 GB seçerseniz uygulama neden başarısız olabileceğini (5117 MB süreç sınırı vs. 4096 MB RAM + 1024 MB JIT + ~380 MB Metal/iOS yükü) açıkça uyarır.
   - 4 GB ile başlatma başarısız olursa `hv_vm_create` / `hv_vmapple_create` tüm kısmi kaynakları (`disk`, `aux`, `b->ram`, `b->rom`, `HvMachine` tabloları) temizler ve uygulamayı kapatmadan **"3 GB RAM ile Tekrar Dene"** düğmesini sunar.
3. **Klavye / İzleme Dörtgeni ve Telemetri:**
   - Sanal Mac çalışırken üstteki yüzen araç çubuğunu (hap menü) sağdaki/soldaki ok düğmesiyle macOS menü çubuğunu kapatmayacak şekilde sağ-üst, üst-orta veya sol-üst köşeye taşıyabilirsiniz.
   - `Ayarlar` menüsünden **İmleç Hızı** ve **Doğal Kaydırma** değiştirdiğinizde sanal Mac'i yeniden başlatmadan anında uygulanır.
   - Oturum içindeki `(i)` düğmesinde **EL0 Açılış Süresi**, **Uygulama Bellek Ayak İzi (`phys_footprint`)**, **Jetsam Öncesi Boş Bellek**, **Derlenen Blok/sn** ve **Kare Hızı (FPS)** canlı olarak izlenebilir; takılı kalan tuşlar **"Takılı Tuşları ve İmleci Sıfırla"** ile tek dokunuşla bırakılabilir.
4. **Temizlenmiş Tanılama Raporu:**
   - `Ayarlar -> Tanılama Raporunu İncele ve Paylaş` ekranından raporu paylaşmadan önce inceleyebilir; eşleştirme anahtarlarının, ECID'lerin, uygulama konteyner UUID'lerinin ve geliştirici Team ID'sinin `<temizlendi>` olarak maskelendiğini doğrulayabilirsiniz.

---

## 5. Geri Dönüş (Rollback) Yöntemi

Herhangi bir sorun yaşarsanız iki farklı katmanda anında geri dönebilirsiniz:

### A. Uygulama / IPA Katmanında Geri Dönüş
- Orijinal `Henge v0.1` (`Henge.ipa`) dosyasını Sideloadly ile aynı Apple ID üzerinden tekrar yükleyin.
- **Sanal Mac'inizi silmenize gerek yoktur:** Bu sürümde `config.plist` geriye dönük uyumlu tutulmuştur (`ramMB = 3072` alanı orijinal ikili yamalı sürümle de uyumludur; orijinal v0.1'de açmak isterseniz `Mac Ayarları`ndan RAM'i değiştirebilir veya `Machines/<UUID>/config.plist` içindeki `ramMB` değerini düzenleyebilirsiniz).

### B. Kaynak Kod Katmanında Geri Dönüş (Git)
- Tüm değişiklikler `feat/keremos-m3-v1` dalında izole edilmiştir, `main` dalı (`da7332e`) orijinal upstream `Leviidev/Henge` kopyasıdır:
  ```bash
  # Orijinal upstream koduna dönmek için:
  git checkout main

  # Veya yalnızca belirli bir dosyayı upstream haline döndürmek için:
  git checkout main -- core/machine.c devices/vmapple.c host/vm.c
  ```

---

## 6. Lisans ve Üçüncü Taraf Bildirimleri

- Proje lisansı **GPL-2.0-or-later** (`LICENSE`) ve `ios/Henge/Resources/legal/` altındaki tüm üçüncü taraf bildirimleri (`StikJIT` MPL-2.0, `idevice` MIT, `QEMU tcg-apple-jit.h` LGPL-2.1, `libirecovery`, `libimobiledevice`, `libplist`, `libslirp`) eksiksiz korunmuştur.

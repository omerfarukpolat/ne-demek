# Ne demek?

İngilizce okurken anlamadığın bir kelimeyi, deyimi ya da cümleyi seç, kısayola bas: Türkçe karşılığı ve kısa açıklaması seçimin hemen yanında, macOS'un Look Up penceresine benzeyen küçük bir popover'da açılır.

*A tiny macOS menu-less helper: select any English phrase, hit a shortcut, and get its Turkish meaning in a minimal popover. Powered by Claude Code.*

```
a bit of a catch
Küçük bir sorun / ufak bir tuzak
Bir şeyin cazip ya da avantajlı göründüğü hâlde beraberinde
getirdiği dezavantaj veya gizli koşulu anlatır.
```

- Her uygulamada çalışır (Safari, Chrome, Önizleme/PDF, Notlar, Mail…) — macOS Hizmetler menüsünü kullanır.
- Hızlı: arka planda hazır bekleyen bir Claude süreci tutulur, yanıt yazıldıkça akar (ilk kelimeler ~1-2 sn).
- Daha önce bakılan ifadeler önbellekten anında gelir.
- Sesli okuma, örnek cümle, düğme yok. Esc / başka yere tıklama kapatır, ⌘C açıklamayı kopyalar.

## Gereksinimler

- macOS 13 veya üstü
- Xcode ya da Command Line Tools (`swiftc` için): `xcode-select --install`
- [Claude Code](https://claude.com/claude-code) kurulu ve giriş yapılmış olmalı (`claude` komutu çalışmalı). Ayrı bir API anahtarı gerekmez.

## Kurulum

```bash
git clone https://github.com/omerfarukpolat/ne-demek.git
cd ne-demek
./build.sh
```

`build.sh` uygulamayı derler, `~/Applications/NeDemek.app` olarak kurar ve başlatır.

### Kısayol atama

**Sistem Ayarları → Klavye → Klavye Kısayolları… → Hizmetler → Metin → "Ne demek?"** satırına istediğin kısayolu ata (ör. ⌃⌥F).

Kısayol olmadan da: metni seç → sağ tık → **Hizmetler → Ne demek?**

## Nasıl çalışır

1. Hizmetler menüsü seçili metni uygulamaya gönderir; popover fare imlecinin altında hemen açılır.
2. Uygulama arka planda her zaman bir `claude -p` sürecini (stream-json modunda, araçsız, kullanıcı ayarları/hook/MCP yüklenmeden) hazır tutar. Soru bu sürece yazılır, yanıt token token popover'a akar.
3. Yanıt bitince süreç kapanır ve bir sonraki soru için yenisi hazırlanır; böylece her soru temiz bir bağlamla, başlatma beklemeden yanıtlanır.
4. Yanıtlar `~/Library/Application Support/NeDemek/cache.json` dosyasında saklanır.

Model ve talimat `main.swift` içindeki `Config` bölümünde.

## Kaynak ve token kullanımı

- Bellek: uygulama ~13 MB, hazırda bekleyen Claude süreci ~130 MB. Boştayken işlemci ~%0.
- Token yalnızca sen bir ifadeye baktığında harcanır: tipik bir sorgu ~500 giriş + ~80 çıkış token. Beklerken model çağrısı yapılmaz; önbellekteki ifadeler hiç token harcamaz.
- Seçtiğin metin Claude Code üzerinden Anthropic'e gönderilir.

## Kaldırma

```bash
pkill -x NeDemek
rm -rf ~/Applications/NeDemek.app ~/Library/Application\ Support/NeDemek
```

## Lisans

MIT

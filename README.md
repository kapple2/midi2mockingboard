# Apple II 모킹보드 툴체인

**모킹보드(Mockingboard)** 사운드 카드(AY-3-8910 두 개: 음 6채널과 드럼용 노이즈)를 단 Apple II에서 음악을 연주하기 위한 전체 과정을 담은
프로젝트입니다. MIDI 파일을 작은 Apple II용 음악 파일로 바꾸고, PC에서 어떻게 들리는지 확인하고, Apple II의 Applesoft BASIC에서
`& MPLAY "SONG"` 명령 하나로 연주합니다.

## 무엇인가

모킹보드에는 샘플 소리가 없습니다. 곡은 두 AY 칩에 보내는 레지스터 쓰기의 흐름일 뿐입니다. 이 프로젝트는 MIDI를 바로 그 흐름으로 바꿔 작은
파일 형식(`.MBF`)에 담고, 양쪽에서 쓰는 도구를 제공합니다:

- **PC 쪽:** 변환기(MIDI → `.MBF`), 두 AY 칩을 스테레오(칩 1은 왼쪽, 칩 2는 오른쪽)로 에뮬레이션해서 Apple II 없이도 결과를 들어 볼 수 있는 플레이어,
  텍스트로 쓴 곡을 컴파일하는 도구, 그리고 끌어다 놓기로 변환과 재생을 하는 창(Mockingboard Studio).
- **Apple II 쪽:** 카드용 드라이버(어느 슬롯에 있든 찾아내고, 타이머로 `.MBF` 스트림을 연주)와, Applesoft 명령 `& MPLAY "NAME"`을 추가하는
  상주 플레이어 `MPLAY`. DOS 3.3 디스크에서 곡을 곧바로 스트리밍하므로 곡은 디스크만큼 클 수 있습니다. BASIC 프로그램 안에 적은 곡도 연주하고,
  반복 재생, 키를 누르면 효과음을 내는 기능도 있습니다.
- **한글 프로젝트와 함께 쓰도록 만들었습니다:** `MPLAY`는 메모리의 고정된 한 구역(`$6900-$89FF`)만 쓰고 `&` 벡터를 이어 받으므로
  K-HANGEUL 드라이버와 KBASIC 옆에서 그대로 돌아갑니다. 일반 DOS 3.3 디스크에서도 됩니다.

## 무엇을 얻는가

| 결과물 | 위치 | 설명 |
| --- | --- | --- |
| **Mockingboard Studio** | `dist\MockingboardStudio.exe` (윈도우. macOS/Linux 빌드는 아래 참고) | MIDI 변환과 `.MBF` 재생을 한 창에서. 파이썬 불필요 |
| **`mb.dsk`** | `dist\mb.dsk` | 부팅 가능한 DOS 3.3 디스크: `MPLAY`, 보통 DOS 파일로 된 곡 다섯 개, 메뉴(`HELLO`), 데모 프로그램 둘(`DEMO`, `PLAYMBF`) |
| **`MPLAY`** | `dist\MPLAY.bin`, `dist\MPLAY.lbl` | 다른 DOS 3.3 디스크(예: K-HANGEUL / KBASIC 디스크)에 바로 넣을 수 있는 상주 플레이어 |
| MIDI 변환기 | `converter\` | MIDI → `.MBF` (6채널에 성부를 배정하고, 드럼은 노이즈 발생기로, 음량은 곡마다 맞춤) |
| PC 플레이어 | `win_player\` | AY-3-8910 두 개를 에뮬레이션해서 `.MBF` 재생. 라이브러리로도 쓸 수 있음 |
| 텍스트 곡 컴파일러 | `tune\` | `T120 CDEFG` 같은 텍스트 곡을 `.MBF`로 (Apple II의 `& MPLAY "!..."`와 같은 알고리즘) |
| Apple II 드라이버 | `mb_apple2\` | `mb_driver.s`(카드 드라이버. 자기 게임에 쓸 수 있음)와 `mb_stream.s`(재생하면서 디스크에서 곡을 읽음) |
| 디스크 빌더와 테스트 | `mb_disk\`, `mb_basic\test\` | 빈 DOS 3.3 이미지로 디스크를 만들고, MAME에서 플레이어를 돌려 모든 AY 레지스터 쓰기를 `.MBF` 파일과 비교 |

## 구성 요소가 이어지는 방식

```
song.mid --converter--> song.MBF --+--> win_player / Studio   (PC에서 듣기)
"T120 CDEFG" --tune--> tune.MBF ---+--> mb_disk --> mb.dsk --> Apple II: & MPLAY "SONG"
```

검증한 것과 하지 않은 것: Apple II 쪽은 MAME에서 AY 레지스터 쓰기를 기록해 확인했습니다(`docs\APPLE2_DRIVER.md`의 테스트 항목 참고). 실제
하드웨어에서는 돌려 보지 않았고, 긴 곡을 스트리밍할 때는 디스크에서 다음 부분을 읽을 때마다 음악이 잠깐(0.1~0.4초) 멈춥니다. 자세한 내용은
`docs\APPLE2_DRIVER.md`(플레이어, 메모리 맵, 한계)와 `docs\TUNE_FORMAT.md`(텍스트 곡 표기법과 `& MPLAY`)에 있습니다.

이 문서들은 한국어가 기본입니다. `X.md`는 한국어, `X_en.md`는 영어판입니다.

## 전부 다시 빌드하기

이 폴더의 `build_all.bat`는 세 단계를 이 순서로 합니다:

1. **MIDI → MBF.** `midi\*.mid`를 모두 `.MBF`(와 `.txt` 덤프)로 변환해서 `..\mbf_out`(`src` 밖, 프로젝트 루트)에 둡니다. 디스크에 들어갈 곡입니다.
   `midi\`에 `.mid`를 추가하면 다음 실행 때 같이 처리됩니다.
2. **`MPLAY`와 디스크.** `mb_disk\build_disk.bat mb.dsk ..\mbf_out`를 부릅니다. 이것이 먼저 `mb_basic\build.bat`(6502 코드를 어셈블/링크해서
   `mb_basic\build\`에 만들고 결과를 `dist\`로 복사)를 실행한 다음, `mb_disk\dos33blank.dsk`의 복사본에 디스크를 씁니다.
3. **Studio.** `mb_studio\build_exe.bat`를 불러 PyInstaller로 Mockingboard Studio를 묶습니다(약 1분).

`dist\`에 생기는 것과 용도:

| 파일 | 만드는 단계 | 용도 |
| --- | --- | --- |
| `mb.dsk` | 2단계 | Apple II 디스크. 부팅해서(AppleWin, MAME, 또는 모킹보드가 있는 실제 Apple II) 메뉴에서 곡을 고릅니다. |
| `MPLAY.bin` | 2단계 | 상주 플레이어. `$7D00`에 로드하는 순수 바이너리입니다. 다른 프로젝트가 자기 DOS 3.3 디스크(예: K-HANGEUL / KBASIC 디스크)에 `MPLAY`라는 **B** 파일로 넣는 것이 이것입니다: `cmd /c "C:\bin\acx.exe -p disk.dsk MPLAY B 0x7D00 < MPLAY.bin"`. 그 뒤 `BRUN MPLAY`가 `& MPLAY`를 설치합니다. |
| `MPLAY.lbl` | 2단계 | `MPLAY.bin`의 링커 레이블 파일(아래 참고). 선택 사항이며, 플레이어 안의 주소가 필요한 사람만 씁니다. |
| `MockingboardStudio.exe` | 3단계 | 윈도우용 Mockingboard Studio. 파일 하나이고 파이썬이 필요 없습니다. |

**`MPLAY.lbl`이란.** 링커(`ld65 -Ln`)가 `MPLAY.bin` 옆에 쓰는 텍스트 파일입니다. 심볼마다 한 줄이고, 그 심볼이 받은 주소가 적혀 있습니다.
예: `al 007D00 .install`(레이블 `install`이 `$7D00`에 있다). 플레이어는 이 파일이 필요 없고 디스크에도 들어가지 않습니다. 플레이어를
다시 빌드하지 않고 어디에 무엇이 있는지 알아야 하는 도구를 위한 것입니다:

- `mb_disk\build_disk.py`는 여기서 `install`을 읽어 `BRUN MPLAY`가 시작하는 주소를 얻습니다.
- MAME 테스트(`mb_basic\test\`)는 여기서 `mb_paused`(곡의 다음 부분을 디스크에서 읽는 동안 음악이 멈춰 있다는 플레이어의 플래그)를 읽어,
  디스크 때문에 멈춘 것과 음표를 구별합니다.
- 다른 프로젝트는 `MPLAY`를 빌드하지 않고 `dist\MPLAY.lbl`에서 플레이어 안의 주소(진입점이나 변수)를 찾아볼 수 있습니다.
  `mb_basic`, `mb_apple2`, `mb_layout.inc`가 바뀌면 `.bin`과 `.lbl`이 한 쌍으로 맞도록 `dist\`를 다시 빌드하세요.

`mb_basic\build\` 폴더에는 맵 파일(`MPLAY.map`, 세그먼트별 크기가 나옴)과 오브젝트 파일도 있습니다. 빌드 부산물이어서 git에는 넣지 않습니다.
macOS / Linux에서 Studio는 `sh mb_studio/build_exe.sh`로 빌드하세요. 파이썬이 PATH에, cc65가 `C:\cc65`에, AppleCommander가 `C:\bin\acx.exe`에
있어야 하고, AppleWin이 `mb.dsk`를 열고 있으면 먼저 닫으세요.

## 필요한 것 (Windows)

| 용도 | 도구 |
| --- | --- |
| 파이썬 프로그램 전부 | PATH에 Python 3.10+ (실행 파일이 처음 실행될 때 `.venv`를 만들고 `requirements.txt`를 설치합니다) |
| 6502 코드 빌드 | `C:\cc65`의 cc65 (또는 `CC65_HOME` 지정) |
| 디스크 빌드 | `C:\bin\acx.exe`의 AppleCommander `acx.exe` (또는 `ACX` 지정) |
| 테스트 실행 | `apple2p` ROM이 있는 MAME 0.289 |

`.venv`는 이 폴더의 한 단계 위(프로젝트 루트)에 만들어집니다.

## 사용법

| 프로그램 | 실행 파일 |
| --- | --- |
| 창 하나에서 변환 + 재생 (끌어다 놓기) | `mb_studio\mb_studio.bat` |
| 단독 실행 exe (파이썬 불필요) | `mb_studio\build_exe.bat` → `dist\MockingboardStudio.exe` |
| macOS / Linux용 단독 실행 앱 | 해당 OS에서 `sh mb_studio/build_exe.sh`, 또는 GitHub Actions 워크플로 (아래 "윈도우, macOS, Linux용 단독 실행 Studio" 참고) |
| MIDI를 MBF로 변환 | `converter\midi2mbf.bat song.mid [대상 폴더] [이름]` |
| PC에서 MBF 재생 | `win_player\play_mbf.bat song.MBF` |
| 텍스트 곡을 MBF로 | `tune\tune2mbf.bat "T120 CDEFG"` |

## 윈도우, macOS, Linux용 단독 실행 Studio

PyInstaller는 교차 컴파일을 하지 못하므로 각 OS에서 직접 빌드해야 합니다. 윈도우와 macOS/Linux는 같은 옵션을 씁니다
(파일 하나, 창 모드, `converter`와 `win_player`는 라이브러리로, `tkinterdnd2` 포함).

| OS | 빌드 | `dist/` 결과물 |
| --- | --- | --- |
| Windows | `mb_studio\build_exe.bat` | `MockingboardStudio.exe` |
| macOS | `sh mb_studio/build_exe.sh` | `MockingboardStudio.app` |
| Linux | `sh mb_studio/build_exe.sh` | `MockingboardStudio-linux` |

- **Linux**는 먼저 시스템 패키지 두 개가 필요합니다: `sudo apt install python3-tk libportaudio2` (tkinter, 그리고 `sounddevice`용 PortAudio).
  다른 배포판에서는 같은 패키지가 다른 이름으로 있습니다.
- **macOS**는 tkinter가 들어 있는 파이썬이 필요합니다(python.org 설치 프로그램에는 들어 있고, Homebrew는 `brew install python-tk`).
  앱에 서명이 없으므로 처음 한 번은 오른쪽 클릭 후 "열기"를 선택해 Gatekeeper를 넘어가야 합니다. 배포하려면 `.app`을 zip으로 묶으세요.
  macOS에서 빌드된 앱의 기본 출력 폴더는 `~/Documents/mbf_out`입니다(exe 옆은 앱 번들 안이 되기 때문입니다).
  윈도우와 Linux에서는 실행 파일 옆의 `mbf_out`입니다.
- `build_exe.sh`는 다른 실행 파일과 같은 `.venv`(이 폴더의 한 단계 위)와 `requirements.txt`를 씁니다.
- **Mac이나 Linux 컴퓨터가 없을 때:** GitHub Actions 워크플로 `.github/workflows/build-studio.yml`이 GitHub 러너에서
  세 OS용을 모두 빌드하고 결과물을 내려받을 수 있게 올려 줍니다(Actions 탭 → Run workflow, 또는 `v*` 태그 푸시).
  `src`가 GitHub 저장소의 루트여야 합니다.
- git에는 윈도우 exe만 커밋하고, Mac과 Linux 결과물은 `.gitignore`에 있습니다.
- 확인하지 않은 것: Mac과 Linux 빌드는 한 번도 실행해 보지 않았고(이 프로젝트는 윈도우에서 만들었습니다), PortAudio를 통한 Linux/macOS 소리 출력도 들어 보지 않았습니다.

## Apple II 디스크 만들기

```
converter\midi2mbf.bat midi\song.mid ..\mbf_out
mb_basic\build.bat
mb_disk\build_disk.bat mb.dsk ..\mbf_out      -> dist\mb.dsk
mb_disk\build_disk.bat out.dsk ..\mbf_out --base KBASIC.DSK     (곡과 MPLAY를 한글 디스크에 넣기)
```

디스크는 `mb_disk\dos33blank.dsk`를 복사해서 시작합니다(원본은 절대 바꾸지 않습니다). 모킹보드가 있는 Apple II+/IIe(48K)나
AppleWin에서 부팅하세요. 디스크에 들어가지 않는 큰 곡은 건너뜁니다.

## 폴더 구성

`converter/` MIDI 변환기, `win_player/` PC 플레이어/AY 에뮬레이터, `tune/` 텍스트 곡 컴파일러,
`mb_studio/` GUI, `mb_apple2/` 모킹보드 드라이버와 디스크 스트리머, `mb_basic/` 상주 플레이어(`& MPLAY`),
`mb_disk/` 디스크 빌더, `midi/` 샘플 MIDI 파일, `dist/` 만들어진 디스크와 exe,
`docs/` Apple II 드라이버와 플레이어(`APPLE2_DRIVER.md`), 텍스트 곡 형식(`TUNE_FORMAT.md`) (각각 `_en.md` 영어판도 있습니다).
테스트: `mb_basic\test\run_basic_tests.bat` (MAME가 필요하고, 변환된 곡이 `..\mbf_out`에 있어야 합니다).

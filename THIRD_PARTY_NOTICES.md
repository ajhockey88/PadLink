# Third-party software

PadLink's own code is MIT licensed (see `LICENSE`). The Windows `PadLinkReceiver.exe` bundles the
following, each under its own license. Their licenses apply to them, not to PadLink's code.

| Component | Used for | License |
|---|---|---|
| [vgamepad](https://github.com/yannbouteiller/vgamepad) 0.1.0 | Creates the virtual Xbox 360 controller | MIT |
| [ViGEmBus](https://github.com/nefarius/ViGEmBus) driver and ViGEmClient (shipped inside vgamepad) | Virtual controller driver, installed on first run | BSD-3-Clause |
| [python-zeroconf](https://github.com/python-zeroconf/python-zeroconf) | Lets the phone find the PC on the network | LGPL-2.1-or-later |
| [ifaddr](https://github.com/ifaddr/ifaddr) | Lists network addresses | MIT |
| [pystray](https://github.com/moses-palmer/pystray) | System tray icon | LGPL-3.0-or-later |
| [Pillow](https://github.com/python-pillow/Pillow) | Draws the tray icon | MIT-CMU (HPND) |
| [PyInstaller](https://github.com/pyinstaller/pyinstaller) bootloader | Packs the exe | GPL-2.0 with a bootloader exception that permits any license for the packed program |
| [Python](https://www.python.org/) | Runtime | PSF License |

The LGPL libraries (python-zeroconf, pystray) are bundled unmodified as ordinary Python modules inside the exe.
To use a different version, run PadLink from source (`pip install -r requirements.txt` then
`python Windows/padlink_receiver.py`), which uses whatever versions you install.

The iPhone app uses only Apple system frameworks.

Check each project's own license text for the full terms. This file is a summary, not legal advice.

# kwin-scripts
Set of KWin scripts for my personal use. Feel free to use it if you like it.

## How to install
You can install scripts in 2 ways:

- Download the script from the release page and drop it in the "KWin scripts" section in the settings.

OR

- Download the entire repository or just the script folders you need,
and place it in `~/.local/share/kwin/scripts/`

## list of scripts

### Resize window on drag
Script resizes the window as it is dragged with mouse.
The User specifies the window sizes individually for each application
or for an entire group of applications in the script's settings. The script automatically attempts to ignore dialog boxes.

Example:
```
Default:900x700 #applies to every app
Default-Exception:gearlever

discord,telegram,spotify:950x750
dolphin,zen,thunderbird:1000x770
kitty,konsole:950x800
```

### Layout auto switch
Script automatically switches the keyboard layout depending on
the active window. The user specifies the layout ID individually for
each application or for an entire group of applications.

Example:
```
# 0,1,2... - are ID's of your keyboard layouts
kitty,dolphin,firefox: 0
telegram, discord: 1
```

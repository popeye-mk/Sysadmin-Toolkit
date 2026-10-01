Put your company images here with exactly these names (or change the names in ..\toolkit-settings.json):

  wallpaper.jpg    desktop background        (.jpg/.png/.bmp, ideally the monitor resolution, e.g. 1920x1080)
  lockscreen.jpg   lock screen               (same formats)
  logo.bmp         OEM logo in Settings > System > About   (120x120 pixels, .bmp)

Set-Branding.ps1 copies them to C:\ProgramData\Sysadmin-Toolkit\Branding on each PC so they keep
working when the share is unreachable. A file that isn't here is simply skipped.

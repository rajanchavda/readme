# Installing Readme on Windows

Readme needs a PC with Windows 11, on an Intel, AMD or ARM processor. There are two ways to get
it: the Microsoft Store, which installs and updates it for you, or an installer from GitHub.

## From the Microsoft Store

1. Open the **Microsoft Store** app and search for **Readme**, or open the link to its page.
2. Click **Get** (or **Install**). The Store downloads and installs it; there's nothing to click
   through.
3. Click **Open**, or find **Readme** in the Start menu.

The Store keeps Readme up to date by itself.

## From GitHub

1. Open the [latest release](https://github.com/rajanchavda/readme/releases/latest) and, under
   **Assets**, download `Readme-Setup-<version>-x64.exe`. On a PC with an ARM processor (such
   as a Snapdragon laptop), download `Readme-Setup-<version>-arm64.exe` instead. Not sure? **Settings > System >
   About > System type** says "x64-based processor" or "ARM-based processor".
2. Open the downloaded file.
3. Windows says **"Windows protected your PC"**, because Readme isn't signed with a paid
   certificate yet. Click **More info**, check that the app is **Readme-Setup-…**, then click
   **Run anyway**. You only see this when installing, not each time you open Readme.
4. The installer first asks who it's for. Choose **Install for me only**, which needs no
   administrator password. (**Install for all users** puts it in Program Files and asks for one.)
5. Click **Next** through where to put it and whether to add a desktop icon, then **Install**, then
   **Finish** to open Readme.

Readme is now in the Start menu. To update it, download and run the newer installer the same way:
it replaces the old version and keeps your books. Close Readme first, or the installer closes it.

To check a download, put the `.sha256` file from the release next to it and, in PowerShell, compare
`(Get-FileHash .\Readme-Setup-<version>-x64.exe).Hash` with the first word in the `.sha256` file.

## Your first book

Drag an EPUB file from File Explorer onto the shelf, then click it to start reading. Or press
**Ctrl+O** to choose one. After installing, you can also double-click an EPUB in File Explorer: if
Windows asks which app to use, choose **Readme**. To make Readme open EPUBs every time, right-click
an EPUB, choose **Open with > Choose another app**, pick **Readme** and click **Always**.

Press **?** while reading to see every keyboard shortcut. On a touchpad, swipe two fingers across
the page to turn it.

## Where your books are kept

Readme copies each book you add into its library, in **Documents\Readme**. Your reading places,
highlights and markers are kept there too. If your Documents folder is backed up to OneDrive, as
it often is, the library is backed up with it, and so it may also appear on your other PCs that use
the same OneDrive.

## Moving your library to another computer

On the shelf, click **…** (top right) > **Export Library…** and save the `.readmelibrary` file.
Open that file on the other computer, Mac or PC, to bring the books, highlights and places across.
A book that's already there is never replaced.

## Uninstalling

Open **Settings > Apps > Installed apps**, find **Readme**, click **…** and choose **Uninstall**.
Or right-click Readme in the Start menu and choose **Uninstall**. This works the same whichever
way you installed it.

Uninstalling removes the app and its settings, such as the theme and the window's size and place,
but **keeps your library**: the books, highlights and places stay in **Documents\Readme**, so they
are all there again if you reinstall. To remove them as well, delete the **Readme** folder in
Documents after uninstalling.

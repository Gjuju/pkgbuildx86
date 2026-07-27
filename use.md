# Testing the librespot build on your Pi

This branch builds the Spotify Connect renderer (librespot) the same way moOde's
**Install** button in Renderer Config does, but caps how many compiler jobs run in
parallel so the board does not run out of RAM and swap to the SD card.

On a 1 GB Pi 3B+ the current moOde build runs 4 jobs: 81 min, and the board
crashed twice during testing. One job took 73 min and wrote far less to the card.

## Run it

```bash
wget https://raw.githubusercontent.com/Gjuju/pkgbuildx86/test/librespot-cargo-jobs/librespot-test-build.sh
chmod +x librespot-test-build.sh
sudo ./librespot-test-build.sh
```

It asks how many parallel jobs to use and suggests a count for your board. Press
Enter to accept the suggestion.

Then wait. The build takes 25 to 90 min depending on the model. Nothing is
installed and no service is touched, so the player keeps working meanwhile.

## Report back

The script ends with a summary block. Copy it into your forum reply:

```text
===== copy this into your forum reply =====
model    Raspberry Pi 3 Model B Plus Rev 1.3
os       Debian GNU/Linux 13 (trixie) (aarch64, arm64)
ram      926 MB, 4 cores
rustc    1.96.0
jobs     1 (advised 1, auto, decided by build.sh)
branch   test/librespot-cargo-jobs @ 802f222
result   OK in 73m12s
disk     8213 MB written to mmcblk0
swap     5104 MB paged out, peak 782 MB in use
load     peak 2.10 (1 min avg, 4 cores), sampled every 30 s
package  librespot_0.8.0-1moode1_arm64.deb
===========================================
```

A build that fails prints the same block, with what it got to. Those runs are the
most useful ones, please post them too.

The full log is `librespot-test-build.log` in your home directory.

## Install what was built

The package is left in your home directory. To install it:

```bash
cd ~
sudo moodeutl --installpkg spotify
```

Then reboot and turn Spotify Connect on in Configure > Renderers.

## Options

```bash
sudo ./librespot-test-build.sh --jobs 4     # force a job count, no prompt
sudo ./librespot-test-build.sh --auto       # no prompt, let the script decide
sudo ./librespot-test-build.sh --help
```

Download the script rather than piping it into a shell - piped, it cannot ask you
anything and will pick the job count on its own.

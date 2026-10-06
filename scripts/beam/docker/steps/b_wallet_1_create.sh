# Sourced by linux_build_and_shoot.sh (STEPS_FILE). 1280x800, fresh data dir.
# B-WALLET-1 / B-UI-CREATE: first run -> add a BEAM wallet -> create.
# The app password is random per run: it protects a throwaway data dir in a
# container that is deleted afterwards.
PW="T$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)9!"
click 640 470 2                                # intro: Create new Campfire
shot linux_01_choose_experience.png            # choose your experience
click 640 722 2                                # Continue
shot linux_02_create_password.png              # create a password
click 640 364; typetext "$PW"
click 640 450; typetext "$PW"
click 640 552 8                                # Next (password key derivation takes a moment)
shot linux_03_my_campfire_empty.png
click 752 685 3                                # Add Wallet
shot linux_04_add_beam_wallet.png
click 640 623 3                                # Create new wallet
shot linux_05_name_wallet.png
click 620 384; typetext "Savings"
shot linux_06_name_typed.png                   # named
click 640 554 3                                # Next
shot linux_07_phrase_warning.png               # recovery phrase warning
click 428 674 1                                # I understand
xdotool mousemove 640 500; for _ in 1 2 3 4 5 6; do xdotool click 5; sleep 0.2; done
shot linux_08_phrase_warning_checked.png       # checked, scrolled to the button
click 640 749 4                                # View recovery phrase (creates the wallet)
shot linux_09_core_not_installed.png           # this build has no pinned Linux core: plain error

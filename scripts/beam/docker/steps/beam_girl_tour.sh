# Sourced by linux_build_and_shoot.sh (STEPS_FILE). 1280x800, fresh data dir.
# Beam girl tour: experience chooser (personas), empty wallets, Add Beam wallet.
# The app password is random per run: it protects a throwaway data dir in a
# container that is deleted afterwards.
PW="T$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)9!"
click 640 470 2                                # intro: Create new Campfire
shot linux_01_choose_experience.png            # choose your experience
click 640 722 2                                # Continue
shot linux_02_create_password.png              # create a password
click 640 364; typetext "$PW"; sleep 1
click 640 450 1; typetext "$PW"; sleep 1
click 640 552 8                                # Next (password key derivation takes a moment)
shot linux_03_my_campfire_empty.png            # empty wallets: the Beam girl "Welcome"
click 752 614 3                                # Add Wallet (button sits under the Welcome sticker)
shot linux_04_add_beam_wallet.png              # Add Beam wallet: girl holding the BEAM logo

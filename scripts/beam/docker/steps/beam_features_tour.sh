# Sourced by linux_build_and_shoot.sh (STEPS_FILE). 1280x800, fresh data dir.
# B-WIRING-1: create a BEAM wallet, open it, and open every BEAM feature once,
# with a screenshot of each.
#
# The app password is random per run: it protects a throwaway data dir in a
# container that is deleted afterwards. The recovery phrase is never shot.
#
# Coordinates. Part 1 (first run → create wallet) repeats b_wallet_1_create.sh
# and beam_girl_tour.sh, which ran on Linux. Every later click is checked by
# test/beam/wiring_ui/beam_click_path_reference_test.dart: each "# @name x y"
# line below must fall inside that control on the real screen laid out at
# 1280x800 (with a panel the width of Campfire's 225 px menu). Still
# estimates: anything a test cannot lay out exactly as the Linux app does —
# fonts differ slightly between macOS and Linux, and My Campfire's wallet row
# depends on that list's layout with one wallet.

PW="T$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)9!"

# ---- 1. first run, create a BEAM wallet (as b_wallet_1_create.sh) ------------
click 640 470 2                                # intro: Create new Campfire
click 640 722 2                                # Continue (experience)
click 640 364 2; typetext "$PW"; sleep 1       # password
click 640 450 2; typetext "$PW"; sleep 1       # confirm
click 640 552 8                                # Next (key derivation takes a moment)
click 752 614 3                                # Add Wallet (under the Beam girl sticker)
click 640 623 3                                # Create new wallet
click 620 384; typetext "Savings"
click 640 554 3                                # Next
click 428 674 1                                # I understand
xdotool mousemove 640 500; for _ in 1 2 3 4 5 6; do xdotool click 5; sleep 0.2; done
click 640 749 8                                # View recovery phrase (creates the wallet)
click 640 661 3                                # I saved my recovery phrase

# ---- 2. the recovery-phrase quiz ------------------------------------------------
# The quiz shows 9 words in random order and asks for word number N; this
# script cannot read the words (and never should). It picks the first word and
# presses Verify: a wrong guess starts a new round on the same screen, a right
# one leaves it. Leaving is seen on the screen itself: the quiz title is gone.
# 1/9 per round, so 40 rounds all fail with probability (8/9)^40 < 1 %.
# @quizWord 500 414
# @quizVerify 640 679
# @quizTitle 640 193
QUIZ_TITLE_CROP="300x36+490+175"                 # around @quizTitle
quiz_title() { import -window root /tmp/quiz_full.png; convert /tmp/quiz_full.png -crop "$QUIZ_TITLE_CROP" +repage "$1"; }
sleep 2
quiz_title /tmp/quiz_ref.png
QUIZ_OK=0
for attempt in $(seq 1 40); do
  click 500 414 1                              # the first of the 9 words
  click 640 679 3                              # Verify
  quiz_title /tmp/quiz_now.png
  changed=$(compare -metric AE /tmp/quiz_ref.png /tmp/quiz_now.png null: 2>&1 || true)
  changed=${changed%% *}; changed=${changed%%.*}
  if [ "${changed:-0}" -gt 300 ]; then QUIZ_OK=1; log "quiz passed on round $attempt"; break; fi
done
[ "$QUIZ_OK" = 1 ] || { log "quiz not passed after 40 rounds"; shot features_00_quiz_failed.png; return 0; }
sleep 3

# ---- 3. My Campfire → the wallet ---------------------------------------------
shot features_01_my_campfire.png
# @openWallet 1195 493
click 1195 493 8                               # "Open wallet" on the only row (Savings)
shot features_02_wallet_home.png               # feature row, Send/Receive/Transactions, Assets

# ---- 4. every feature once ------------------------------------------------------
# At 1280x800 the feature row holds Swap and Names; dApps, Airdrops, Tokens,
# Node & sync and Split coins are under its "More".
# @rowSwap 874 161
# @swapClose 1200 72
click 874 161 4;  shot features_03_swap.png;            click 1200 72 2
# @rowNames 1025 161
# @namesBack 266 41
click 1025 161 4; shot features_04_names.png;           click 266 41 2
# @rowMore 1173 161
# @moredApps 459 238
# @dappsBack 274 41
click 1173 161 2; shot features_05_more.png
click 459 238 4;  shot features_06_dapps.png;           click 274 41 2
# @moreAirdrops 469 327
# @airdropsClaim 640 337
# @claimBack 274 41
click 1173 161 2; click 469 327 3; shot features_07_airdrops_menu.png
click 640 337 4;  shot features_08_claim_code.png;      click 274 41 2
# @moreTokens 462 416
# @tokensCreate 640 337
# @mintBack 274 41
click 1173 161 2; click 462 416 3; shot features_09_tokens_menu.png
click 640 337 4;  shot features_10_create_token.png;    click 274 41 2
# @moreNodesync 488 505
# @nodeClose 890 233
click 1173 161 2; click 488 505 4; shot features_11_node_sync.png; click 890 233 2
# @moreSplitcoins 478 594
# @splitBack 274 41
click 1173 161 2; click 478 594 4; shot features_11b_split_coins.png; click 274 41 2
# @walletOptions 1226 41
# @addressList 1173 59
# @addressListClose 920 72
click 1226 41 2;  click 1173 59 4; shot features_12_address_list.png; click 920 72 2
# @tabTransactions 633 306
click 633 306 2;  shot features_13_transactions_tab.png

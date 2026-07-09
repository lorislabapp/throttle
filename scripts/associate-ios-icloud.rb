#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Associate the iCloud container + App Group to the iOS companion App IDs.
#
# WHY: The public App Store Connect API can enable the ICLOUD / APP_GROUPS
# *capabilities* on a bundle id, but it cannot associate the specific
# iCloud.com.lorislab.throttle container or group.com.lorislab.throttle group —
# there is no public appGroups/cloudContainers resource (both 404). That gap is
# only reachable through the private Developer Portal API, i.e. Spaceship.
# Without the association, `xcodebuild archive` fails:
#   "Provisioning profile … doesn't support the … iCloud Identifier / App Group".
#
# Auth: a fresh FASTLANE_SESSION (the portal cookie expires ~30 days). Regenerate
# with `fastlane spaceauth -u dev@kevinn.ie` (SMS 2FA), then export it before
# running this. Password auto-injects from Bitwarden; the 2FA code is device-only.
#
#   export FASTLANE_SESSION="$(fastlane spaceauth -u dev@kevinn.ie 2>/dev/null | sed -n '/-----/,$p')"
#   ruby scripts/associate-ios-icloud.rb
#
# Homebrew fastlane bundles Spaceship inside its monorepo gem; if `require
# "spaceship"` fails, run through fastlane's ruby/gem env (see the wrapper at
# $(brew --prefix)/bin/fastlane) or add the -I load paths for
# .../gems/fastlane-*/{spaceship,fastlane_core,credentials_manager}/lib.
#
# Idempotent: creates the App Group if missing, then enables services + associates
# on both App IDs. Re-mint the profiles afterwards (provision-ios-appstore.mjs).

require 'spaceship'

USER       = ENV['FASTLANE_USER'] || 'dev@kevinn.ie'
TEAM_ID    = 'TDV6D5L785'
GROUP_ID   = 'group.com.lorislab.throttle'
CONTAINER  = 'iCloud.com.lorislab.throttle'
APP_BID    = 'com.lorislab.throttle.ios'
WIDGET_BID = 'com.lorislab.throttle.ios.widget'

Spaceship::Portal.login(USER, nil) # nil password → relies on FASTLANE_SESSION
Spaceship::Portal.client.team_id = TEAM_ID

group = Spaceship::Portal.app_group.all.find { |g| g.group_id == GROUP_ID }
group ||= Spaceship::Portal.app_group.create!(group_id: GROUP_ID, name: 'Throttle Group')
cont = Spaceship::Portal.cloud_container.all.find { |c| c.identifier == CONTAINER }
abort "iCloud container #{CONTAINER} not found on the portal" unless cont
puts "group=#{group.group_id}  container=#{cont.identifier}"

# Main app: iCloud + CloudKit + App Groups, then associate the specific identifiers.
app = Spaceship::Portal.app.find(APP_BID)
app.update_service(Spaceship.app_service.app_group.on)
app.update_service(Spaceship.app_service.cloud.on)
app.update_service(Spaceship.app_service.cloud_kit.cloud_kit)
Spaceship::Portal.app.find(APP_BID).associate_groups([group])
Spaceship::Portal.app.find(APP_BID).associate_cloud_containers([cont])
puts "#{APP_BID}: associated group + container"

# Widget: App Groups only.
Spaceship::Portal.app.find(WIDGET_BID).update_service(Spaceship.app_service.app_group.on)
Spaceship::Portal.app.find(WIDGET_BID).associate_groups([group])
puts "#{WIDGET_BID}: associated group"
puts 'done — now re-run scripts/provision-ios-appstore.mjs to re-mint the profiles'

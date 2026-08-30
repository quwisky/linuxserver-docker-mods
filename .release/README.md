# Release state

`plan.json` is generated on the rolling `release/next` branch. Its merge is the
authorization to promote the listed immutable candidates, create protected
package tags, and publish GitHub Releases. Do not edit a plan by hand; edit the
source files under `.changes/` and let the release App regenerate it.

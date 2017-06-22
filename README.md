# isobuilder tool for creating an ISO image from an installation app

* Download the pre-release version or desired release of the new operating system from https://developer.apple.com/osx/download/
* Copy the whole app onto any vmbuilder machine
* Clone this repo on that vmbuilder on your home dir
* Run isobuilder

## Running isobuilder
* `cd isobuilder`
* `sudo -s`
* `export OSX_VERSION=$"10.11"` # replace 10.11 with whatever version the new installer is for
* `bash -x convert_iso.sh "/url/to/install/package/Install OS X El Capitan GM Candidate.app"` # again replace app name with the correct name for you

The isobuilder should run without issues.  If it does not, ask Vilmos for help because no one else can save you from your doom.



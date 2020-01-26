I realized that Zoom.us kept a local SQLLite database of chat archives and 
needed a cheap way to get stuff from it. 

I followed the following steps:
* Load the data from macOS usually found under:
  ```
     ~/Library/Application\ Support/zoom.us/data/<someuserid>@xmpp.zoom.us
  ```
* There you will find a `*.db` file that you can use to load into datagrip 
* Export that data into a folder in CSV folder
* Run this against the CSV file
* Edit this script i wrote to change EPOCH UTC times in CSV files to your 
local TZ in my case "Americas/Costa_Rica"
* Then you can open up those CSVs into Excel or whatever but at least no
date conversions...
* you can use this for any CSV that needs EPOCH UTC to any TZ conversion


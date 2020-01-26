I realized that Zoom.us kept a local SQLLite database of chat archives and 
needed a cheap way to get stuff from it. So I followed the following steps:
* Load the data from macOS usually found under:
  ```
     ~/Library/Application\ Support/zoom.us/data/<someuserid>@xmpp.zoom.us
  ```
* There you will find a `*.db` file that you can use to load into datagrip 
* Export that data into a folder in CSV folder
* Run this against the CSV file
* Edit this to change EPOCH UTC times in CSV files to your local TZ


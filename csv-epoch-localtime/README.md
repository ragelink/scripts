# csv-epoch-localtime

Rewrites epoch UTC timestamps in a CSV file as local time, in place. Written to
make Zoom's local chat archive readable in a spreadsheet; it works for any CSV
with epoch columns once the column numbers are adjusted.

## Background

Zoom keeps a local SQLite database of chat archives. On macOS it lives under:

```
~/Library/Application Support/zoom.us/data/<user-id>@xmpp.zoom.us/
```

Open the `*.db` file there with any SQLite client (DataGrip, the `sqlite3`
shell, ...) and export the table you want to CSV.

## Usage

```sh
pip install pytz
python3 parse-chats.py export.csv
```

The script rewrites the file in place, so keep a copy of the original. It:

- keeps the header row;
- reads column 2 as epoch seconds (sent time) and column 13 as epoch
  milliseconds (received time);
- converts both from UTC to the time zone set in `load_csv()`
  (`America/Costa_Rica`).

For another CSV or time zone, edit the column indexes (`row[1]`, `row[12]`) and
the zone name in `parse-chats.py`. After that the CSV opens in Excel or any
spreadsheet without date conversions.

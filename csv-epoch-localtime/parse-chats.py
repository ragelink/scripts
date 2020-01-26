#!/usr/local/bin/python3

import os.path, time, csv, shutil, pytz, datetime
from tempfile import NamedTemporaryFile
from datetime import datetime
from pytz import timezone
from sys import argv

def is_file(file_name):
  if(not os.path.isfile(file_name)):
    raise ValueError("You must provide a valid filename as parameter")

def load_csv():
  tzlocal = pytz.timezone("America/Costa_Rica")
  with open(file_name,'r', encoding='utf8') as csv_file, tempfile:
    csv_reader=csv.reader(csv_file)
    csv_writer=csv.writer(tempfile)
    headers = next(csv_reader, None)  # returns the headers or `None` if the input is empty
    if headers:
      csv_writer.writerow(headers)
    for row in csv_reader:
      #get epoch row
      sent=row[1]
      received=row[12]
      #convert from epoch to datetime and add UTC
      timesent=datetime.fromtimestamp(int(sent), pytz.UTC)
      timereceived=datetime.fromtimestamp((int(received) / 1000),pytz.UTC)
      #convert from UTC to local
      sent=timesent.astimezone(tzlocal)
      received=timereceived.astimezone(tzlocal)
      #write out
      row[1]=sent
      row[12]=received
      csv_writer.writerow(row)
  return

if __name__ == "__main__":
  tempfile = NamedTemporaryFile(mode='w', delete=False)
  try:
    file_name=argv[1]
    is_file(file_name)
    pass
  except Exception as e:
    print("You must provide a valid filename as parameter")
    raise
    
  load_csv()
  shutil.move(tempfile.name, file_name)


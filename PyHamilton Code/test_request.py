import requests

url = 'http://10.146.92.218:5000'
dict = {'go_left': 'Go Left'}

x = requests.post(url, data='go_right')
print(x)
#Author: Benjamin Pyatski
#Company: Chory Lab

from flask import Flask, render_template, request, jsonify
import RPi.GPIO as GPIO
import time
import os
import A4988
import redis

r = redis.Redis()

GPIO.setmode(GPIO.BCM)

#define GPIO pins
direction= 22 # Direction (DIR) GPIO Pin
step = 23 # Step GPIO Pin
EN_pin = 24# enable pin (LOW to enable)

# Declare a instance of class pass GPIO pins numbers and the motor type
my_motor = A4988.A4988Nema(direction, step, (11,9,10), "A4988")
GPIO.setup(EN_pin,GPIO.OUT) # set enable pin as output


GPIO.output(EN_pin,GPIO.LOW) # pull enable to low to enable motor

print("running motor")

clockwise = False
start = time.time()

GPIO.setup(4, GPIO.IN)

while(1==1):
    print(GPIO.input(4) == 0)

my_motor.motor_go(False, # True=Clockwise, False=Counter-Clockwise
                "Half", # Step type (Full,Half,1/4,1/8,1/16,1/32)
                2000, # number of steps
                0.001, # step delay [sec]
                True, # True = print verbose output 
                0.05) # initial delay [sec]

r.set('stop_motor', 'True')

my_motor.motor_go(True, # True=Clockwise, False=Counter-Clockwise
                "Half" , # Step type (Full,Half,1/4,1/8,1/16,1/32)
                2000, # number of steps
                0.001, # step delay [sec]
                True, # True = print verbose output 
                0.05) # initial delay [sec]

end = time.time()
print(end-start)

GPIO.output(EN_pin,GPIO.HIGH)

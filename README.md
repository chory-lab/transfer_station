[comment]: <> (Author: Benjamin Pyatski)
[comment]: <> (Company: Chory Lab)


<h1>Introduction</h1>
This repository holds the code (and previously used test code) for the functioning of the transfer system, or just the step motor rail. There are two parts to this README detailing the software components, and the hardware components of the transfer station system.

<h2>Software</h2>
This section details the usage of the code.

<h3>api_step_motor.py</h3>
The system is setup in such a way where the majority of the fucntional code is in api_step_motor, which creates a UI through flask (and handles subsequent interactions with said UI) that the user can input commands to. 

<h3>A4988.py</h3>
In order for the stepper motor to connect to the Raspberry Pi 4 it is necessary to utilize a A4988 controller, and the python file of the same name holds all the function definitions utilized in api_step_motor.py and the microswitches, and handles the connection between the Raspberry Pi 4 and the stepper motor on the rail.

<h3>FLow Chart</h3>

![image](https://github.com/chory-lab/transfer_station/assets/69654071/d1da2de6-53cc-47c6-a860-9d3476c1888c)

<h3>Installation</h3>

* Install flask (make sure it is ver 2.2.2 or newer otherwise --app feature won't work, check this by running flask --version):
  
    ```pip install --upgrade Flask ```

* Install reddis:

    ```pip install redis```

* Install flask_caching:
  
    ```pip install flask_caching```

<h3>Setup (Skip if setup already running)</h3>
The first step is to get start the flask and redis server, the redis server handling multiple calls at the same time to allow asynchronous running of the code. 
<br><br>

1. Activate the Virtual Environment
    - Navigate to the location of the virtual environment:
    
      ```cd /home/git/transfer_station```
    - Activate the virtual environment:
    
      ```source foobar/bin/activate```
    
2. In another terminal, start the redis server:
   
    ```redis-server```  

4. Run the code through flask (on the previously setup virtual environment) and open the outputted link (first one is for the local machine, second is for a different machine on the same wifi):

    ```flask --app api_step_motor run --host=0.0.0.0```

<h2>Hardware</h2>
The hardware can be categorized into two parts, the actual circuitry required to run the transfer station, and then the physical components that actually make up the parts of the transfer station itself. 

<h3>Transfer Station Circuitry</h3>
The transfer station consists of a step motor rail connected through a motor driver (A4988 Stepper Motor Driver) to a computer (Raspberry Pi Zero 2 W) on which the code is running. The wiring diagram can be seen below:

![image](https://github.com/chory-lab/transfer_station/assets/69654071/a2e29e91-b305-4fbc-8b5c-8c84075bc933)

<h4>A4988 Stepper Motor Driver</h4>

![image](https://github.com/chory-lab/transfer_station/assets/69654071/13c0050c-7d20-4bd9-b880-a7aa17810c33)

Pin Index:
  - ENA -> Enable pin. When low A4988 is enabled, when high A4988 is disabled
  - RES -> Reset pin
  - SLP -> Sleep pin (connected to RES so SLP triggers code RES)
  - STP -> Step. Reads how many steps requested for the step motor to take
  - DIR -> Direction.
  - VMT -> Energy supply to power step motor
  - GND -> Ground
  - 2B, 2A, 1A, 1B -> Control for Bipolar Step Motor (Power, Step, Direction)
  - VDD -> Power for A4988

<h4>Raspberry Pi Zero 2 W</h4>

![image](https://github.com/chory-lab/transfer_station/assets/69654071/397a1f29-71f6-4400-840c-6d2acba378ad)

![image](https://github.com/chory-lab/transfer_station/assets/69654071/97159fb8-87ad-45c7-b7d0-eb24ef14be5d)

Pin Index:
  - 2 -> 5V Power to supply A4988
  - 6 -> Ground
  - 15 -> GPIO22, programmable pin
  - 16 -> GPIO23, programmable pin
  - 18 -> GPIO24, programmable pin

Any GPIO can be used as they are all programmable

<h3>Transfer Station System</h3>
The system is composed of 4 core components, these consist of the tray, tray platform, step motor rail system, and the mount. All components were printed with PLA plastic, and default 3D printer settings. Screws used were the default ones that come with the Hamilton Star, and the default bolts that came with the incubator mount. 

<h4>Tray</h4>
This is holds the 96 well plate (or equivalent size) when delivering the plate to the incubator, and vice versa.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/5e6d066a-dbb4-403d-9bdd-c4cc44f140a3)

<h4>Tray Platform</h4>
This raises the tray to the needed height for the incubator to be able to reach the plate.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/3565bda2-becf-4eeb-828e-3ba721c507a8)

<h4>Stepper Motor Rail System</h4>
This comprises of a stepper motor, connected to a rail system (screw) that spins moving a cart that is already on the screw.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/2178c803-b7bc-447f-a207-de881839ab26)

<h4>Mount</h4>
This is what the stepper motor rail system is screwed onto connecting/supporting the stepper motor rail system on the incubator.

![image](https://github.com/chory-lab/transfer_station/assets/69654071/8c9b438e-2e05-4f78-83f6-389a6350ffdf)

<h4>Assembly</h4>
The final assembly consists of:

  1. Screw mount onto incubator with M6 x 12mm screws (x2)

  2. Screw stepper motor rail system to the mount with M3 x 12mm screws (x4)
  
  3. Screw tray platform onto cart with M4 x 8mm screws (x4)
  
  4. Slide tray onto pegs on tray platform
  
![image](https://github.com/chory-lab/transfer_station/assets/69654071/2ea4342a-1d0f-4a60-ac54-e75c83075aa1)

![IMG_2489](https://github.com/chory-lab/transfer_station/assets/69654071/6cb466e3-b27b-4c4f-b220-d72cb4b66d85)

<h2>Parts List</h2>
1. 3D Printed Pieces

  - Mount
  
  - Tray

  - Tray Stand
<br>
2. Screws

  - M6 x 12mm (x2) -> Used for screwing mount onto incubator
    - https://www.amazon.com/PZRT-Hexagon-Socket-Countersunk-Stainless/dp/B08DF82569/ref=sr_1_11?crid=4DQCMXP4GQAZ&dib=eyJ2IjoiMSJ9.LIPtxz7Q5zTQQilsP_mo008b4pMHIWmHuQ720JEpOsFdaYlHN8LrANsgnHg5Ysbh8qXjYzT52biXEKR5GlfR4dHKsG4vxE6ysnHjFGUBHmuh0OJ7xeddjvSaguY1JImV6tWXzGDL5JyStOGngBdTygjJK5l7hoKika0_cMVsavOlynd-pgmOmzjRDgW6s3uKuT5VSKeSULYWakfDjJ3cjqC7uYYcQ4o9MtgXsStmpZs.zjiJT6gXKT8KD1W3KD2S6uGaLnkheQmfjYbNg_evdII&dib_tag=se&keywords=the%2Ba2-70%2Bbolt%2B12%2Bx%2B6&qid=1715367034&sprefix=the%2Ba2-70%2Bbolt%2B12%2Bx%2B6%2Caps%2C170&sr=8-11&th=1

  - M4 x 8mm (x4) -> Used for screwing tray platform onto cart
    - https://www.amazon.com/Socket-Screws-Metric-Machine-Threaded/dp/B0969NLFKW/ref=sr_1_1_sspa?crid=TY0NJ6U27D6W&dib=eyJ2IjoiMSJ9.T4FnBHNc5nvHguwvqZdhlpLj6FUAFWeK9QReCzsGAYReNHLWQJW3gWz3tb3vXL-PByVFq5leU247cdXgW0cMeR7oUdt4h6C_Q7hS07qnFzIKxTFAnqt2mdousxt5Emva7nfX_mJPuE2hD5gmTV4v54tMjhizl34UzSpMEJibxKJYMhQ_ctJN59qOoG0c7RVIrKbcjQN3Q6iudCKvmz2UBnebbf5Lt_9ERBOqS7v6T9ToHmRlLnLx2cLLlSHj9LdcNAz4bMfmypGhMsYnvrtF7ZzVfuzjhxr5B_vm6Bl1IU8.AnoHgxmFQR-HwbuRKF5YqoVtBtESvCxRAs0hURdmjSI&dib_tag=se&keywords=m4%2Bx%2B9&qid=1715367254&s=hi&sprefix=m4%2Bx%2B9%2Ctools%2C157&sr=1-1-spons&sp_csd=d2lkZ2V0TmFtZT1zcF9hdGY&th=1

  - M3 x 12mm (x4) -> Used for screwing rail onto mount
    - https://www.amazon.com/SUNXULIMI-Socket-Furniture-Stainless-Threaded/dp/B0CMDVK2QK/ref=sr_1_1_sspa?crid=2EAFIZ14FR2N4&dib=eyJ2IjoiMSJ9.XBVxtXZCu16yzamFewEx3RD8Fu6XA2mLkz6qRg9iTw4bFX7WU9gJaB-ImrHu-00KMMVldpca7Ehg9MrnYFHOh-Q7du1eSdqTb4vhw68zIUsUITIWnWm5H2G-ag4Dfg648XON4MdT-gaPyy2MyUbmduYc76nFvK3sn5n1fOeGxi0CLilI1Vht1R3iOFZ4ffNv7QGI6qWl2HMIVCt2gnNh93e1MpFXQwnXBS8jUMpQ06zO16jHf4qrptF8cIK9WpqijAsietMqs6HERn5OrdOTNw6gd5Vn5t1wfg3dPQYeX_w.zgVGKykv2EG8onQbxvmg3IDkZq2iORxMtXPFSrs-ifQ&dib_tag=se&keywords=m3%2Bx%2B12&qid=1715367419&s=hi&sprefix=m3%2Bx%2B1%2Ctools%2C107&sr=1-1-spons&sp_csd=d2lkZ2V0TmFtZT1zcF9hdGY&th=1
<br>

3. A4988 Stepper Motor Drive -> Needs seperate power cable
  - https://www.amazon.com/WWZMDiB-Stepstick-Stepper-Printer-Suitable/dp/B0BFQZWT6R/ref=sr_1_2_sspa?crid=BXMA21BJZFUR&dib=eyJ2IjoiMSJ9.-DERZWswWeLIrDX-CE6W2eUaDTj3Hse7vymBmv-5DaU86ahz6vvxX2T_9RnZS9wpUMFaTXt0kM5b501wAbyo8JcrPEHZvG0vIGuSA4m96sDXJ9XmNpnMZWsy1tRva1fV17v5v1jBhDDgbgP951V04iH0_PsoX44f46Kyej_z92YO8vj3G8RaJT2jcvNgjojsWUoNw98jcZ2swwNRqJ92M_6hMuKSVHy4HpC_Dl7E_A8.WpNk_oUq1mXg1puht4JrrBkYhmKFKayyfXhNf7olYDQ&dib_tag=se&keywords=A4988%2Bdriver&qid=1715367645&sprefix=a4988%2Bdrive%2Caps%2C135&sr=8-2-spons&sp_csd=d2lkZ2V0TmFtZT1zcF9hdGY&th=1
<br>

4. Raspberry Pi Zero 2 W -> Needs seperate power cable, and male header pins to solder on
  - https://www.amazon.com/Raspberry-Quad-core-Bluetooth-onboard-Antenna/dp/B0CCRP85TR/ref=sr_1_1_sspa?crid=31CITI545J2LE&dib=eyJ2IjoiMSJ9._aa2DALNqDdQhYnlXw1mxoDktKjOgpHnHu2JjT_rcWxWrDRzbTeOdGo7RMfSkGMRV-Mziw-gU9HVWVdf840aZ_JY80VJra3m0X_9WvtE6l4EeLJrgzQfQd28BpVD3j8nplJ5LlRrtqo6lc-J1-XaARy-3XHt8GxJLpus3bxjsS-XPJuZQlttR8EYRT8pQYkCF0LVFD6CZh3EpAL0PV__bj2LyocsYkhMI5ls4F022zg.Zu7DdM9AfSvLf8MKw5uIWmHoi4gyth1FtPzrpLbAvFI&dib_tag=se&keywords=raspberry+pi+zero+2+w&qid=1715367706&sprefix=raspberry+pi+zero+2+w%2Caps%2C104&sr=8-1-spons&sp_csd=d2lkZ2V0TmFtZT1zcF9hdGY&psc=1

5. Stepper Motor Rail System
  -  https://www.amazon.com/FUYU-Linear-Module-Actuator-Stepper/dp/B0CG5PPKXY/ref=sr_1_2_sspa?crid=CIFUWO83AQSG&dib=eyJ2IjoiMSJ9.Tl5dPAzpScab3jUGWYx4yYB9-kuIAvTp1HGtkAMGeZ2ddMavjIlrmjbEtA2pRskiQwosZ6ahYWtzqZcv-Ag4vCL0JGMtHCXwt4nBiTo67LBgzMT4GrErAs5Pf_5CSRmwXwvWSfRLr__Jyq0Spl-g8Xu-5kN5tV7P0o_17FRxlqP4salzZkJLHYD9VSsO1rNCoCSIZAQ5w-CibIcj7wTn7j3oA3aMLOKu_u9qA5i-C6A.C-5n9PkGCahuyOtgaikKZ6Aen9ltO_3ofrZL0GMneqA&dib_tag=se&keywords=stepper%2Bmotor%2Brail&qid=1715367746&sprefix=stepper%2Bmotor%2Brail%2Caps%2C106&sr=8-2-spons&sp_csd=d2lkZ2V0TmFtZT1zcF9hdGY&th=1

6. Powered USB hub with mini USB connector -> Used for connecting keyboard and mouse to raspbery pi zero 2 w
  - https://www.amazon.com/AuviPal-Adapter-Playstation-Classic-Raspberry/dp/B083WML1XB/ref=sr_1_6?crid=3CMJ55CPE0AMD&dib=eyJ2IjoiMSJ9.oEfjxkOlNOTQqeG3O-c5YhvGvwPDpvkwObvKTvKU6duvTYrgnNnvzAYpNRAvd6PM9BR5CxAUCkRURNKSZ82bw8SkySiVbqVgP21E772eLnKlvtkJGpVSs2lUarFtGxLHpBor_3toBI68q4eteT7Hb6LYkGb-QCfWfcuZd9XL019m43o12YvIm_lcRHlEYFwryZ0f4FWtkpTJA4bRvKqGeIEDs2z-evmi1WLvGrPD4do.6EBM29lrqhramCMlycLT825Qe4_ephRpIP21n6FjR7w&dib_tag=se&keywords=powered+usb+hub+mini+usb&qid=1715368304&sprefix=powered+usb+hub+mini+usb%2Caps%2C100&sr=8-6



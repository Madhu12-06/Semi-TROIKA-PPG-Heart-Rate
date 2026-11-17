# Semi-TROIKA: PPG Heart Rate Estimation During Exercise

## Project Overview
This project implements a Digital Signal Processing (DSP) pipeline to estimate heart rate from wrist-worn Photoplethysmography (PPG) signals during physical exercise. Wrist PPG is highly susceptible to motion artifacts (arm swinging, running cadence). This project implements a "Semi-TROIKA" approach to robustly track the heart rate.

## DSP Pipeline
1. **Criterion 1: ACC-Guided Denoising** - Bandpass filtering (0.5–4.0 Hz) and extraction of the dominant Accelerometer axis to act as a motion reference.
2. **Criterion 2: High-Resolution Spectrum** - Utilization of the Chirp Z-Transform (CZT) to zoom in on the 0.7–4.0 Hz band, achieving 1024 frequency bins (0.2 BPM resolution).
3. **Criterion 3: Spectral Peak Tracking** - A temporal tracker using continuity scores, strict ACC penalties, and a sub-harmonic summation check to prevent locking onto motion frequencies or harmonics.

## Performance
Tested on a 300-window subset of the IEEE SP Cup 2015 dataset:
* **Mean Absolute Error (MAE): 6.93 BPM**
* **RMSE: ~9.5 BPM**

## Repository Structure
* `SemiTROIKA.m` : The main MATLAB script containing the DSP pipeline.
* `IEEEPPG_TRAIN.csv` : The dataset used for evaluation.
* `Plots/` : Contains the evaluation graphs (Tracking, Scatter, CZT Spectrum, Denoising, and Error Histogram).

## How to Run
1. Open MATLAB.
2. Place `IEEEPPG_TRAIN.csv` and `SemiTROIKA.m` in the same folder.
3. Run `SemiTROIKA.m`. The script will output the MAE/RMSE to the command window and generate 5 evaluation plots.

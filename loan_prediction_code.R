library(rstudioapi)
library(dplyr)
library(tidyr)
library(ggplot2)
library(margins) # margins()
library(pROC)
library(ROCR) # for evaluation using AUC
library(lmtest)
library(sandwich)
library(InformationValue)
library(pscl) # pseudo R2
library(LogisticDx) # gof
library(stargazer)

#### Loading data ####

setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

loan <- read.csv("data/loan.csv",
  sep = ";",
  na.strings = c("", " ", NA),
  header = T
)

glimpse(loan)
summary(loan)
# some NA values found


#### Plotting NAs ####
na_vec <- rep(NA, ncol(loan))

for (i in 1:ncol(loan)) {
  na_value <- sum(is.na(loan[, i])) / length(loan[, i])
  na_vec[i] <- na_value
}

names <- colnames(loan)
barplot(na_vec, names.arg = names, cex.names = 0.6, las = 2, 
        ylab = "Proportion of missing values")


#### Categorical variables to factors ####

loan <- loan %>%
  select(-Loan_ID, -Loan_Status)

# Rewrite "character" variables as factors
for (j in 1:ncol(loan)) {
  if (class(loan[, j]) == "character") {
    loan[, j] <- as.factor(loan[, j])
  }
}

# Also recategorize dummies and variables with recurring values
loan <- loan %>%
  mutate(
    Credit_History = as.factor(Credit_History),
    Dependents = as.factor(Dependents),
    Loan_Amount_Term = as.factor(Loan_Amount_Term),
    Loan_Status_Int = as.factor(Loan_Status_Int)
  )

glimpse(loan)
summary(loan)

# Do our variables still contain nonsensical values?
for (i in 1:ncol(loan)){
  uniq_vec <- unique(loan[, i])
  if (length(uniq_vec) > 12){
    print(paste("Too many unique values in ", colnames(loan)[i], 
                " , but the vector's type is ", class(loan[, i]), sep = ""))
    print("----------", quote = F)
  } else {
    print(colnames(loan)[i], quote = F)
    print(uniq_vec)
    print("----------", quote = F)
  }
}

## rendering the summary table
# library(summarytools)
# loan %>%
#    dfSummary(graph.magnif = 0.5, na.col = T, valid.col = F) %>%
#    print(method = "render")


#### Densities of numeric variables ####

loan %>%
  na.omit() %>%
  select_if(is.numeric) %>%
  gather() %>%
  ggplot(aes(value)) +
  facet_wrap(~key, scales = "free") +
  geom_density()

# log transforms
loan %>%
  na.omit() %>%
  select_if(is.numeric) %>%
  gather() %>%
  filter(value > 0) %>%
  ggplot(aes(log(value))) +
  facet_wrap(~key, scales = "free") +
  geom_density()


#### Barcharts of categorical variables ####

# loan %>%
#   select_if(is.factor) %>%
#   gather() %>%
#   ggplot(aes(value)) +
#   facet_wrap(~ key, scales = "free") +
#   geom_bar()

# How many times a client repaid on time / did not repay on time conditional on ...
loan_cat <- loan %>%
  select_if(is.factor) %>%
  select(-Loan_Status_Int)

par(mar = c(1, 1, 1, 1))
par(mfrow = c(3, 3))
for (k in 1:ncol(loan_cat)) {
  var <- table(loan$Loan_Status, loan_cat[, k])
  barplot(var,
    las = 1,
    cex.names = 0.85,
    xlab = colnames(loan_cat)[k],
    legend.text = rownames(var)
  )
}
par(mfrow = c(1, 1))


#### Barcharts of binned numerical vars ####

# Binning numerical variables to see the Loan_Status_Int rate
loan_num <- loan %>%
  select_if(is.numeric) %>%
  mutate(Loan_Status_Int = loan$Loan_Status_Int) %>%
  na.omit()

glimpse(loan_num)

# " - 1 " to not include Loan_Status_Int
for (l in 1:(ncol(loan_num) - 1)) {
  bin <- c(
    -Inf,
    as.numeric(quantile(loan_num[, l], probs = seq(0.1, 0.9, 0.1))),
    Inf
  )
  name <- paste(colnames(loan_num)[l], "_bin", sep = "")

  # "1" signifies that the value lies in the interval (-Inf, 0.1), "2" in (0.1, 0.2) ...
  loan_num[, name] <- .bincode(loan_num[, l], breaks = bin)
  loan_num[, name] <- as.factor(loan_num[, name])
}

glimpse(loan_num)

# 1-2 = Low, 5-6 = Medium, 9-10 = High
par(mfrow = c(2, 2))
for (k in 1:ncol(loan_num)) {
  var <- table(loan_num$Loan_Status_Int, loan_num[, k])
  barplot(var,
    las = 1,
    cex.names = 0.85,
    xlab = colnames(loan_num)[k],
    legend = rownames(var)
  )
}
par(mfrow = c(1, 1))


#### Finding the best categorical variables ####

# define variable names that are categorical and numeric
all_vars <- setdiff(colnames(loan), "Loan_Status_Int")
categ_vars <- all_vars[sapply(loan[, all_vars], class) %in% c("factor", "character")]
num_vars <- all_vars[sapply(loan[, all_vars], class) %in% c("numeric", "integer", "double")]

# create training/test sets and set a seed for repeatable results
set.seed(14097)
grouping <- runif(nrow(loan))
loan_train <- subset(loan, grouping <= 0.8)
loan_test <- subset(loan, grouping > 0.8)

# tabulate some variable in context with the outcome variable
sample_table <- table(
  Married = loan_train$Married,
  Loan_Status_Int = loan_train$Loan_Status_Int,
  useNA = "ifany"
)
sample_table

# we are interested in conditional probabilities
print(sample_table[, 2] / (sample_table[, 1] + sample_table[, 2]))


# Choose "Married" variable as an example
# and "Loan_Status_Int" as the outcome variable
var_name <- categ_vars[2]
var_col <- loan_train[, var_name]
out_col <- loan_train$Loan_Status_Int
var_col_t <- loan_test[, var_name]

# Create a function that calculates conditional probabilities as illustrated above
make_prediction_cat <- function(out_col, var_col_t, var_col) {
  var_table <- table(out_col, var_col)
  na_table <- table(as.factor(out_col[is.na(var_col)]))

  positive_prob <- sum(out_col == "1") / length(out_col)
  positive_prob_var <- var_table["1", ] / colSums(var_table)
  positibe_prob_na <- (na_table / sum(na_table))["1"]

  prediction <- positive_prob_var[var_col_t]
  prediction[is.na(prediction)] <- positive_prob

  return(prediction)
}

head(make_prediction_cat(out_col, var_col_t, var_col))

# automate for all categorical variables
for (var in categ_vars) {
  pred_i <- paste(var, "_pred", sep = "")

  loan_train[, pred_i] <- make_prediction_cat(
    loan_train[, "Loan_Status_Int"],
    loan_train[, var],
    loan_train[, var]
  )
  loan_test[, pred_i] <- make_prediction_cat(
    loan_test[, "Loan_Status_Int"],
    loan_test[, var],
    loan_test[, var]
  )
}

head(loan_train)
head(loan_test)


# calculate area under curve to determine the "best" variables

auc_calc <- function(pred_col, out_col) {
  # "pred_col" represent the column of predictions
  # and "out_col" represents the actual outcomes
  perf <- performance(ROCR::prediction(pred_col, out_col == "1"), "auc")

  as.numeric(perf@y.values)
}

for (var in categ_vars) {
  pred_i <- paste(var, "_pred", sep = "")

  loan_train_auc <- auc_calc(loan_train[, pred_i], loan_train[, "Loan_Status_Int"])

  loan_test_auc <- auc_calc(loan_test[, pred_i], loan_test[, "Loan_Status_Int"])


  training_AUC <- round(loan_train_auc, 4)
  testing_AUC <- round(loan_test_auc, 4)

  # print all the values and their respective AUCs
  print(paste(pred_i, "training AUC:", training_AUC))
  print(paste(pred_i, "testing AUC:", testing_AUC))
}


#### Finding the best numerical variables ####

make_prediction_num <- function(out_col, var_col_t, var_col) {

  # 10 cuts
  bins <- as.numeric(quantile(var_col, probs = seq(0, 1, 0.1), na.rm = T))
  unique_bins <- unique(bins)

  var_col_bin <- cut(var_col, unique_bins)
  var_col_t_bin <- cut(var_col_t, unique_bins)

  make_prediction_cat(out_col, var_col_t_bin, var_col_bin)
}

for (var in num_vars) {
  pred_i <- paste(var, "_pred", sep = "")

  loan_train[, pred_i] <- make_prediction_num(
    loan_train[, "Loan_Status_Int"],
    loan_train[, var],
    loan_train[, var]
  )
  loan_test[, pred_i] <- make_prediction_num(
    loan_test[, "Loan_Status_Int"],
    loan_test[, var],
    loan_test[, var]
  )

  loan_train_auc <- auc_calc(loan_train[, pred_i], loan_train[, "Loan_Status_Int"])

  loan_test_auc <- auc_calc(loan_test[, pred_i], loan_test[, "Loan_Status_Int"])

  training_AUC <- round(loan_train_auc, 4)
  testing_AUC <- round(loan_test_auc, 4)

  print(paste(pred_i, "training AUC:", training_AUC))
  print(paste(pred_i, "testing AUC:", testing_AUC))
}


#### Model data preparation ####

# Based on AUC, subset the dataset to maximize the number of 
# observations due to missing values in "useless" variables

loan_model <- loan %>%
  select(Married, Property_Area, ApplicantIncome, Credit_History, 
         LoanAmount, Loan_Status_Int, Education) %>%
  # Converting factors to exact numerical variables
  mutate(Loan_Status_Int = as.numeric(as.character(Loan_Status_Int))) %>%
  filter(ApplicantIncome > 0) %>%
  na.omit()

glimpse(loan_model)


#### Linear probability model ####

# Baseline LPM model
fmla_0 <- Loan_Status_Int ~ Credit_History

model_lpm0 <- lm(fmla_0, data = loan_model)
summary(model_lpm0)

# Correct for heteroskedastic errors
(model_lpm0_rob <- coeftest(model_lpm0, vcov = vcovHC(model_lpm0, type = "HC0")))


# Larger LPM model
fmla_1 <- Loan_Status_Int ~ Credit_History + Married + Property_Area + log(ApplicantIncome)

model_lpm1 <- lm(fmla_1, data = loan_model)
summary(model_lpm1)

# Correct for heteroskedastic errors
(model_lpm1_rob <- coeftest(model_lpm1, vcov = vcovHC(model_lpm1, type = "HC0")))

# Fitted values above 1
plot(model_lpm1$fitted.values)


#### Probit / Logit models ####

# Copy the formula for clarity
fmla_1 <- Loan_Status_Int ~ Credit_History + Married + Property_Area + log(ApplicantIncome)
# Alternative formulas also yield satisfactory results but higher AIC
fmla_1a <- Loan_Status_Int ~ Married + Property_Area + Credit_History
fmla_1b <- Loan_Status_Int ~ Married + Property_Area + Credit_History + log(ApplicantIncome) + LoanAmount 
fmla_1c <- Loan_Status_Int ~ Married + Property_Area + Credit_History + Education

model_prob0 <- glm(fmla_0, data = loan_model, family = binomial(link = "probit"))
summary(model_prob0)
(avg_part_eff_prob0 <- margins(model_prob0))

model_log0 <- glm(fmla_0, data = loan_model, family = binomial(link = "logit"))
summary(model_log0)
(avg_part_eff_log0 <- margins(model_log0))


model_prob1 <- glm(fmla_1, data = loan_model, family = binomial(link = "probit"))
summary(model_prob1)
(avg_part_eff_prob1 <- margins(model_prob1))

model_log1 <- glm(fmla_1, data = loan_model, family = binomial(link = "logit"))
summary(model_log1)
(avg_part_eff_log1 <- margins(model_log1))


# Comparison of fitted values
plot(model_log1$fitted.values)
points(model_prob1$fitted.values, col = "red")


#### Tests and evaluation ####

# pseudo R2 measures
pR2(model_prob1)
pR2(model_log1)


# Confusion matrix
pred_lpm1 <- predict(model_lpm1, loan_model, type = "response", na.rm = T)
pred_prob1 <- predict(model_prob1, loan_model, type = "response", na.rm = T)
pred_log1 <- predict(model_log1, loan_model, type = "response", na.rm = T)

table(loan_model$Loan_Status_Int, pred_lpm1 > 0.5)
table(loan_model$Loan_Status_Int, pred_prob1 > 0.5)
table(loan_model$Loan_Status_Int, pred_log1 > 0.5)

opt_cutoff_lpm1 <- optimalCutoff(loan_model$Loan_Status_Int, predictedScores = pred_lpm1)
opt_cutoff_prob1 <- optimalCutoff(loan_model$Loan_Status_Int, predictedScores = pred_prob1)
opt_cutoff_log1 <- optimalCutoff(loan_model$Loan_Status_Int, predictedScores = pred_log1)

table(loan_model$Loan_Status_Int, pred_lpm1 > opt_cutoff_lpm1)
table(loan_model$Loan_Status_Int, pred_prob1 > opt_cutoff_prob1)
table(loan_model$Loan_Status_Int, pred_log1 > opt_cutoff_log1)

# # # # # #
# TN | FP #
# ------- #
# FN | TP #
# # # # # #

# sum(loan_model$Loan_Status_Int == 1 & pred_prob1 > opt_cutoff_log1) # TP
# sum(loan_model$Loan_Status_Int == 1 & pred_prob1 < opt_cutoff_log1) # FN
# sum(loan_model$Loan_Status_Int == 0 & pred_prob1 > opt_cutoff_log1) # FP
# sum(loan_model$Loan_Status_Int == 0 & pred_prob1 < opt_cutoff_log1) # TN


# Likelihood ratio test
fmla_00 <- Loan_Status_Int ~ 1
model_prob00 <- glm(fmla_00, data = loan_model, family = binomial(link = "probit"))
model_log00 <- glm(fmla_00, data = loan_model, family = binomial(link = "logit"))

# Testing against a constant model
lrtest(model_prob00, model_prob0)

# Reject the null that Credit_History is insignificant
lrtest(model_log00, model_log0)

# Joint significance of Married, Prop_Area + log(AppInc)
lrtest(model_prob0, model_prob1) 
lrtest(model_log0, model_log1) 
# not insignificant in both models


# Wald test
waldtest(model_lpm1)
waldtest(model_prob1)
waldtest(model_log1)


# ROCR plot, AUC and other diagnostics
auc(loan_model$Loan_Status_Int, pred_lpm1)
gof(model_log1)
gof(model_prob1)


# Graphical comparison of the fitted values
temp_df <- data.frame(model_lpm1$fitted.values,
                      model_prob1$fitted.values,
                      model_log1$fitted.values)
colnames(temp_df) <- c("LPM", "Probit", "Logit")
boxplot(temp_df)

stargazer(model_lpm1_rob, model_prob1, model_log1,
          title = "Determining loan defaults",
          header = F,
          type = "latex",
          keep.stat = NULL,
          omit.table.layout = "n",
          digits = 4,
          intercept.bottom = F,
          column.labels = c("LPM", "Probit", "Logit"),
          dep.var.labels.include = F,
          model.numbers = F,
          dep.var.caption = "Dependent variable: Loan Status Int",
          model.names = F
)

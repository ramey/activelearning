#' Active learning with "Query by Committee"
#'
#' The 'query by committee' approach to active learning uitilizes a committee of C classifiers that are each trained on the labeled training data. Our goal is to "query the oracle" with the observations that have the maximum disagreement among the C trained classifiers.
#'
#' Note that this approach is similar to "Query by Bagging" (QBB), but each committee member is specified by the user. With the QBB approach, only one supervised classifier is specified by the user, and each committee member is trained on a resampled subset of  the labeled training data. Also, note that we we have implemented QBB as query_by_bagging.
#'
#' To determine maximum disagreement among committee committe members, we have implemented three approaches:
#' 1. vote_entropy: query the unlabeled observation that maximizes the vote entropy among all commitee members
#' 2. post_entropy: query the unlabeled observation that maximizes the entropy of average posterior probabilities of all committee members
#' 3. kullback: query the unlabeled observation that maximizes the Kullback-Leibler divergence between the label distributions of any one committe member and the consensus.
#' The 'disagreement' argument must be one of the three: 'kullback' is the default.
#'
#' To calculate the committee disagreement, we use the formulae from Dr. Burr Settles' "Active Learning Literature Survey" available on his website. At the time this function was coded, the literature survey had last been updated on January 26, 2010.
#'
#' In specifying the committee members, we require a list (called 'committee' in the arguments) with elements corresponding to each supervised classifier (each committee member). Each component in the list 'committee' should be a list with the following named elements:
#'    train: a string that specifies the function name of the supervised classifier
#'    (optional) train_args: a list that specifies additional arguments to pass to the 'train' function
#'    predict: a string that specifies the classifier's corresponding prediction (classification) function
#'
#' We require that each training function (specified in 'train') accept x and y as the matrix of observations and their labels of class membership, respectively. A function wrapper can be used to satisfy our requirement. The 'train_args' is a named list that contains the arguments that will be passed to the function specified in 'train'. Lastly, the 'predict' function should accept the trained object from 'train' as its first argument and a matrix of unlabeled test observations as its second argument. Furthermore, we assume that the 'predict' function returns a list that contains a 'posterior' component that is a matrix of the posterior probabilities of class membership and a 'class' component that is a vector with the classification of each test observation; the (i,j)th entry of the 'posterior' matrix must be the posterior probability of the ith observation belong to class j.
#'
#' We provide an example here that uses the linear discriminant analysis (LDA) implementation in the MASS package as well as the regularized discriminant analysis (RDA) implementation in the klaR package. Each training function arguments 'x' for the data matrix and 'grouping' as the vector of class labels. Furthermore, the RDA classifier accepts two optional tuning parameters, lambda and gamma. If the models are not provided they are estimated automatically. In our example, we consider using both the RDA model with and without user-specified tuning parameters. Note that both the LDA and RDA classifiers use 'predict' as their classification functions. The specified 'committee' can be formulated by:
#'
#' lda_wrapper <- function(x, y, ...) { rda(x = x, grouping = y, ...) }
#' rda_wrapper <- function(x, y, ...) { rda(x = x, grouping = y, ...) }
#' rda_args <- list(lambda = 1, gamma = 0.1)
#'
#' committee <- list(
#'    LDA = list(train = 'lda_wrapper', predict = 'predict'),
#'    RDA = list(train = 'rda_wrapper', train_args = rda_args, predict = 'predict'),
#'    RDA_auto = list(train = 'rda_wrapper', predict = 'predict')
#' )
#'
#' Unlabeled observations in 'y' are assumed to have NA for a label.
#'
#' It is often convenient to query unlabeled observations in batch. By default, we query the unlabeled observation with the largest disagreement measure value. With the 'num_query' the user can specify the number of observations to return in batch. If there are ties in the disagreement measure values, they are broken by the order in which the unlabeled observations are given.
#'
#' This method uses the 'foreach' package and is set to do the train each committee member in parallel if a parallel backend is registered. If there is no parallel backend registered, a warning is thrown, but everything will work just fine.
#'
#' @param x a matrix containing the labeled and unlabeled data
#' @param y a vector of the labels for each observation in x. Use NA for unlabeled.
#' @param committee a list containing the committee of classifiers. See details for the required format.
#' @param disagreement a string that contains the disagreement measure among the committee members. See above for details.
#' @param num_query the number of observations to be be queried.
#' @return a list that contains the least_certain observation and miscellaneous results. See above for details.
query_by_committee <- function(x, y, committee, disagreement = "kullback", num_query = 1) {
	unlabeled <- which(is.na(y))
	n <- length(y) - length(unlabeled)
  
  train_x <- x[-unlabeled, ]
  train_y <- y[-unlabeled]
  test_x <- x[unlabeled, ]

	# Committee predictions
	committee_pred <- foreach(c_member = committee) %dopar% {
	  cl_predict <- get(c_member$predict)
	  args_string <- paste(names(c_member$train_args), c_member$train_args$train_args, sep = "=", collapse = ", ")
	  args_string <- paste('x = train_x, y = train_y, ', args_string, sep = "")
    function_call <- paste(c_member$train, "(", args_string, ")", sep = "")
    train_out <- eval(parse(text = function_call))
		cl_predict(train_out, test_x)
	}
	
	committee_post <- lapply(committee_pred, function(x) x$posterior)
	committee_class <- do.call(rbind, lapply(committee_pred, function(x) x$class))
	
	if(uncertainty == "vote_entropy") {
    obs_disagreement <- apply(committee_class, 2, function(x) {
      entropy.empirical(table(factor(x, levels = classes)))
    })
  } else if(uncertainty == "post_entropy") {
    committee_post <- lapply(committee_pred, function(x) x$posterior)
    average_posteriors <- Reduce('+', committee_post) / length(committee_post)
    obs_disagreement <- apply(average_posteriors, 1, function(obs_post) {
      entropy.plugin(obs_post)
    })
  } else if(uncertainty == "kullback") {
    committee_post <- lapply(committee_pred, function(x) x$posterior)
    consensus_prob <- Reduce('+', committee_post) / length(committee_post)
    kl_post_by_member <- lapply(committee_post, function(x) rowSums(x * log(x / consensus_prob)))
    obs_disagreement <- Reduce('+', kl_post_by_member) / length(kl_post_by_member)
  } # else: Should never get here
	
	query <- order(obs_uncertainty, decreasing = T)[seq_len(num_query)]
	
	list(query = query, obs_disagreement = obs_disagreement, committee_class = committee_class, committee_post = committee_post, unlabeled = unlabeled)
}
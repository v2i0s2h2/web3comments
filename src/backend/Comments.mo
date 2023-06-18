import Nat "mo:base/Nat";
import Time "mo:base/Time";
import List "mo:base/List";
import Error "mo:base/Error";
import Principal "mo:base/Principal";
import Array "mo:base/Array";


import Types "Types";
import Constants "Constants";
import {
    validateComment;
    hashComment;
    userToQueryUser;
    fundsAvalaible;
} "Utils";

module {
    type State = Types.State;
    type Users = Types.Users;

    type User = Types.User;

    type Comment = Types.Comment;
    type CommentHash = Types.CommentHash;

    type PostResult = Types.PostResult;
    type LikeResult = Types.LikeResult;
    type DeleteResult = Types.DeleteResult;

    type QueryComment = Types.QueryComment;
    type QueryUser = Types.QueryUser;

    // Constants
    let COMMENT_REWARD = Constants.COMMENT_REWARD;
    let LIKE_REWARD = Constants.LIKE_REWARD;

    let COMMENT_INTERVAL = Constants.COMMENT_INTERVAL;
    let LIKE_INTERVAL = Constants.LIKE_INTERVAL;

    let ADMIN = Constants.ADMIN_PRINCIPALS;

    // PUBLIC METHOD IMPLEMENTATIONS

    public func register(users : Users, principal : Principal) : QueryUser {
        switch (users.get(principal)) {

            // If user doesn't exist, create a new one
            case (null) {
                let newUser : User = {
                    id = users.size() + 1;
                    balance = 0;
                    lastPost = 0;
                    lastLike = 0;
                    likes = List.nil<CommentHash>();
                };

                users.put(principal, newUser);

                userToQueryUser(newUser);
            };

            // If user exists, return it
            case (?user) { userToQueryUser(user) };
        };
    };

    public func postComment(state : State, owner : Principal, comment : Text) : PostResult {
        // Check if comment is valid
        if (not validateComment(comment)) return #err(#InvalidComment);

        switch (state.users.get(owner)) {

            // Users must be registered before posting
            // If user doesn't exist, return error
            case (null) { #err(#UserNotFound) };

            // If user exists, post comment
            case (?user) {
                let now = Time.now();

                // Check if user has posted recently
                if (now - user.lastPost < COMMENT_INTERVAL) {
                    return #err(#TimeRemaining(COMMENT_INTERVAL - (now - user.lastPost)));
                };

                // Create new comment record
                let postComment : Comment = {
                    created = now;
                    owner;
                    comment;
                    reward = 0;
                };
                let hash = hashComment(postComment);

                // If treasury is not empty, subtract and add an equal amount of funds
                var reward = 0;
                if (fundsAvalaible(state.treasury, COMMENT_REWARD)) {
                    state.treasury -= COMMENT_REWARD;
                    reward += COMMENT_REWARD;
                };
                
                let balance = user.balance + reward;

                // Create new user record
                let newUser : User = {
                    user with
                    balance;
                    lastPost = now;
                    likes = List.make<CommentHash>(hash);
                };

                // Update state within atomic block after all checks have passed
                state.users.put(owner, newUser);

                state.commentStore.put(hash, postComment);

                state.commentHistory := List.push<CommentHash>(hash, state.commentHistory);

                #ok();
            };
        };
    };

    public func likeComment(state : State, hash : CommentHash, liker : Principal) : async* LikeResult {
        // Like the comment if possible
        switch (state.users.get(liker)) {

            // Users must be registered before liking
            case (null) { return #err(#UserNotFound) };

            // If user exists, like comment
            case (?user) {
                let now = Time.now();

                // Check if user has liked this comment before
                if (List.some<CommentHash>(user.likes, func(h : CommentHash) : Bool { h == hash })) {
                    return #err(#AlreadyLiked);
                };

                // Check if user has liked recently
                if (now - user.lastLike < LIKE_INTERVAL) {
                    return #err(#TimeRemaining(LIKE_INTERVAL - (now - user.lastLike)));
                };

                // Add comment to user's liked comments list
                let newUser : User = {
                    user with
                    lastLike = now;
                    lastPost = now;
                    likes = List.push<CommentHash>(hash, user.likes);
                };

                // Update state within atomic block after all checks have passed
                state.users.put(liker, newUser);
            };
        };

        // Update comment reward and user balance
        switch (state.commentStore.get(hash)) {

            // If comment doesn't exist, return error
            // Error is thrown before any state updates
            case (null) throw Error.reject("Comment not found");

            // If comment exists, update reward and balance
            case (?comment) {
                switch (state.users.get(comment.owner)) {
                    case (null) {
                        throw Error.reject("Comment has no owner");
                    };
                    case (?owner) {
                        // If treasury is not empty, subtract and add to user balance and comment total reward
                        var likeReward = 0;
                        if (fundsAvalaible(state.treasury, LIKE_REWARD)) {
                            state.treasury -= LIKE_REWARD;
                            likeReward += LIKE_REWARD;
                        };
                        let reward = comment.reward + likeReward;
                        let balance = owner.balance + likeReward;
    
                        // Create new comment and owner records
                        let newComment : Comment = {
                            comment with
                            reward;
                        };
                        let newOwner : User = {
                            owner with
                            balance;
                        };

                        // Update state within atomic block after all checks have passed
                        state.commentStore.put(hash, newComment);
                        state.users.put(comment.owner, newOwner);

                        #ok(newComment.reward);
                    };

                };
            };
        };
    };

    public func latestComments(state : State) : [QueryComment] {
        // Take the latest 50 comment hashes
        let latestHashes = List.take<CommentHash>(state.commentHistory, 50);

        // Map comment hashes to [QueryComment]
        let comments = List.mapFilter<CommentHash, QueryComment>(
            latestHashes,
            func(hash : CommentHash) : ?QueryComment {
                switch (state.commentStore.get(hash)) {
                    case (null) return null;
                    case (?comment) {
                        switch (state.users.get(comment.owner)) {
                            case (null) return null;
                            case (?user) {
                                let userId = "User" # Nat.toText(user.id);
                                ?{
                                    created = comment.created;
                                    userId;
                                    reward = comment.reward;
                                    comment = comment.comment;
                                    hash;
                                };
                            };
                        };
                    };
                };
            },
        );
        List.toArray(comments);
    };

    
    //check principal is admin or not
    func isAdmin(p : Principal) :  Bool {
        if(Principal.equal(p , Principal.fromText(ADMIN[0]))){
            true
        }else if(Principal.equal(p , Principal.fromText(ADMIN[1]))){
            true
        }else {
            return false
        }
    
    };

    public func deleteComment(state: State, owner: Principal, commentHash: CommentHash) : async* () {
    // Check if user is an admin

    if (not isAdmin(owner)) {
        throw Error.reject("Not Admin");
    };

    //  argument funtion for list.some
    func change(x : CommentHash) : Bool {
    x == commentHash;
    };

    // Check if the comment exists
    switch(state.commentStore.get(commentHash)) {
        case(null) {  throw Error.reject("CommentNotFound");};
        case(?comment) {
            func check(arg : CommentHash) : Bool {
               not (arg == commentHash)
            };

        // Delete the comment from the commentStore and update relevant data structures
          state.commentHistory := List.filter<CommentHash>(state.commentHistory, check);
          return ()
         };
    }; 
        
};
}
